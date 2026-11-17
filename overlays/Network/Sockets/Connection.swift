// NWConnection over a non-blocking BSD socket. All of a connection's work happens on the queue it
// is started on, the queue its handlers and completions are called on: dispatch sources on the
// socket drive the connect, the TLS handshake and the reads and writes, and every public method
// hands its request to that queue. TLS is libnetwork's libtls client session (darling_tls.m),
// configured from the sec_protocol_options the app set. Not provided: DTLS, a TLS server side,
// Bonjour service endpoints, establishment and data transfer reports.
import Darwin
import Dispatch
import Foundation

// OSStatus codes (SecBase.h).
private let errSSLBadConfiguration: Int32 = -9848
private let errSSLXCertChainInvalid: Int32 = -9807
private let errSSLClosedAbort: Int32 = -9806

@_objcRuntimeName(_TtC7Network13_NWConnection)
public final class NWConnection: CustomDebugStringConvertible {
	public enum State: Equatable {
		case setup
		case waiting(NWError)
		case preparing
		case ready
		case failed(NWError)
		case cancelled

		public static func == (a: State, b: State) -> Bool {
			switch (a, b) {
			case (.setup, .setup), (.preparing, .preparing), (.ready, .ready), (.cancelled, .cancelled): return true
			case (.waiting(let x), .waiting(let y)), (.failed(let x), .failed(let y)): return x == y
			default: return false
			}
		}
	}

	@_objcRuntimeName(_TtCC7Network13_NWConnection14ContentContext)
	public class ContentContext {
		public final let identifier: String
		public final let expirationMilliseconds: UInt64
		public final let relativePriority: Double
		public final let antecedent: ContentContext?
		public final let isFinal: Bool
		private let metadata: [NWProtocolMetadata]

		public var protocolMetadata: [NWProtocolMetadata] { metadata }

		public func protocolMetadata(definition: NWProtocolDefinition) -> NWProtocolMetadata? {
			metadata.first { $0.definition == definition }
		}

		public init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5, isFinal: Bool = false,
		            antecedent: ContentContext? = nil, metadata: [NWProtocolMetadata]? = []) {
			self.identifier = identifier
			self.expirationMilliseconds = expiration
			self.relativePriority = priority
			self.isFinal = isFinal
			self.antecedent = antecedent
			self.metadata = metadata ?? []
		}

		public static let defaultMessage = ContentContext(identifier: "NWConnection.ContentContext.defaultMessage")
		public static let finalMessage = ContentContext(identifier: "NWConnection.ContentContext.finalMessage", isFinal: true)
		public static let defaultStream = ContentContext(identifier: "NWConnection.ContentContext.defaultStream")
	}

	public enum SendCompletion {
		case contentProcessed((_ error: NWError?) -> Void)
		case idempotent
	}

	public final let endpoint: NWEndpoint
	public final let parameters: NWParameters

	// Shared with the caller's threads, under the lock.
	private let lock = NSLock()
	private var _queue: DispatchQueue?
	private var beforeStart: [() -> Void] = []
	private var _state: State = .setup
	private var _stateUpdateHandler: ((State) -> Void)?
	private var _pathUpdateHandler: ((NWPath) -> Void)?
	private var _viabilityUpdateHandler: ((Bool) -> Void)?
	private var _betterPathUpdateHandler: ((Bool) -> Void)?
	private var _currentPath: NWPath?
	private var _tlsMetadata: NWProtocolTLS.Metadata?
	private var _socket: SocketHandle?

	// The rest is the queue's alone.
	private enum Phase { case idle, resolving, connecting, handshaking, ready, waiting, failed, cancelled }
	private var phase: Phase = .idle
	private var inbound: SocketHandle?
	private var socket: SocketHandle?
	private var readWatch = SocketWatch()
	private var writeWatch = SocketWatch()
	private var tls: darling_nw_tls_t?
	private var candidates: [SocketAddress] = []
	private var lastError: NWError?
	private var attemptTimer: DispatchSourceTimer?
	private var connectTimer: DispatchSourceTimer?
	private var generation = 0

	private struct Receive {
		let minimum: Int
		let maximum: Int
		let wholeMessage: Bool
		let completion: (Data?, ContentContext?, Bool, NWError?) -> Void
	}

	private struct Send {
		var data: Data
		var offset = 0
		var written = false
		let isNil: Bool
		let isFinal: Bool
		let completion: SendCompletion
	}

	private var receives: [Receive] = []
	private var sends: [Send] = []
	private var inboxData = Data()
	private var datagrams: [Data] = []
	private var readEOF = false
	private var wroteFinal = false

	public init(to: NWEndpoint, using: NWParameters) {
		endpoint = to
		parameters = using
	}

	public convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {
		self.init(to: .hostPort(host: host, port: port), using: using)
	}

	/// A connection a listener accepted, already connected.
	internal init(accepted handle: SocketHandle, remote: NWEndpoint, parameters: NWParameters) {
		endpoint = remote
		self.parameters = parameters
		inbound = handle
	}

	deinit {
		darling_nw_tls_free(tls)
	}

	private func locked<T>(_ body: () -> T) -> T {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}

	public final var debugDescription: String { "[C] \(endpoint.debugDescription) \(parameters.debugDescription)" }

	public final var state: State { locked { _state } }

	public final var stateUpdateHandler: ((_ state: State) -> Void)? {
		get { locked { _stateUpdateHandler } }
		set { locked { _stateUpdateHandler = newValue } }
	}

	public final var maximumDatagramSize: Int { parameters.isDatagram ? 65_507 : 0 }

	public final var currentPath: NWPath? { locked { _currentPath } }

	public final var pathUpdateHandler: ((_ newPath: NWPath) -> Void)? {
		get { locked { _pathUpdateHandler } }
		set { locked { _pathUpdateHandler = newValue } }
	}

	public final var viabilityUpdateHandler: ((_ isViable: Bool) -> Void)? {
		get { locked { _viabilityUpdateHandler } }
		set { locked { _viabilityUpdateHandler = newValue } }
	}

	/// Never called: Darling has one path.
	public final var betterPathUpdateHandler: ((_ betterPathAvailable: Bool) -> Void)? {
		get { locked { _betterPathUpdateHandler } }
		set { locked { _betterPathUpdateHandler = newValue } }
	}

	public final var queue: DispatchQueue? { locked { _queue } }

	public final func start(queue: DispatchQueue) {
		let queued: [() -> Void]? = locked {
			guard _queue == nil else { return nil }
			_queue = queue
			defer { beforeStart = [] }
			return beforeStart
		}
		guard let queued = queued else { return }
		queue.async {
			self.begin()
			queued.forEach { $0() }
		}
	}

	/// Runs `work` on the connection's queue, or once it has one.
	private func perform(_ work: @escaping () -> Void) {
		let queue: DispatchQueue? = locked {
			if _queue == nil { beforeStart.append(work) }
			return _queue
		}
		queue?.async(execute: work)
	}

	public final func cancel() {
		perform { self.finish(.cancelled) }
	}

	public final func forceCancel() {
		cancel()
	}

	/// Moves on to the next address, when there is one still to try.
	public final func cancelCurrentEndpoint() {
		perform {
			guard self.phase == .connecting else { return }
			self.closeSocket()
			self.tryNextAddress()
		}
	}

	/// Tries again from the start, after the connection waited.
	public final func restart() {
		perform {
			guard self.phase == .waiting else { return }
			self.begin()
		}
	}

	// MARK: Establishment

	private func setState(_ state: State) {
		let handler: ((State) -> Void)? = locked {
			_state = state
			return _stateUpdateHandler
		}
		handler?(state)
	}

	private func begin() {
		guard phase == .idle || phase == .waiting else { return }
		generation += 1
		lastError = nil
		setState(.preparing)
		if let handle = inbound {
			inbound = nil
			guard parameters.tlsOptions == nil else {
				// Darling has no TLS server side.
				fail(.tls(errSSLBadConfiguration))
				return
			}
			attach(handle)
			becomeReady()
			return
		}
		if let tcp = parameters.tcpOptions, tcp.connectionTimeout > 0 {
			connectTimer = timer(after: Double(tcp.connectionTimeout)) { [weak self] in
				guard let self = self, [.resolving, .connecting, .handshaking].contains(self.phase) else { return }
				self.fail(.posix(.ETIMEDOUT))
			}
		}
		switch endpoint {
		case .hostPort(let host, let port):
			resolve(host: host, port: port.rawValue)
		case .url(let url):
			let defaultPort: UInt16 = ["https", "wss"].contains(url.scheme?.lowercased() ?? "") ? 443 : 80
			guard let host = url.host else { return wait(.posix(.EINVAL)) }
			resolve(host: NWEndpoint.Host(host), port: url.port.map { UInt16($0) } ?? defaultPort)
		case .unix(let path):
			guard let address = SocketAddress(unixPath: path) else { return wait(.posix(.ENAMETOOLONG)) }
			candidates = [address]
			phase = .connecting
			tryNextAddress()
		case .service:
			// No Bonjour resolution in Darling.
			wait(.dns(-65554))
		case .opaque:
			wait(.posix(.EINVAL))
		}
	}

	private func timer(after seconds: Double, _ handler: @escaping () -> Void) -> DispatchSourceTimer? {
		guard let queue = queue else { return nil }
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + seconds)
		timer.setEventHandler(handler: handler)
		timer.resume()
		return timer
	}

	private func resolve(host: NWEndpoint.Host, port: UInt16) {
		if let address = SocketAddress(host: host, port: port) {
			candidates = [address]
			phase = .connecting
			tryNextAddress()
			return
		}
		guard case .name(let name, _) = host, let queue = queue else { return }
		phase = .resolving
		let generation = self.generation, version = parameters.ipVersion, datagram = parameters.isDatagram
		DispatchQueue.global().async {
			let result = Network.resolve(name: name, port: port, version: version, datagram: datagram)
			queue.async {
				guard self.phase == .resolving, self.generation == generation else { return }
				switch result {
				case .success(let addresses):
					// IPv4 first: an Android device often has an IPv6 address but no IPv6 route.
					self.candidates = addresses.filter { $0.family == AF_INET } + addresses.filter { $0.family != AF_INET }
					self.phase = .connecting
					self.tryNextAddress()
				case .failure(let error):
					self.wait(error)
				}
			}
		}
	}

	private func tryNextAddress() {
		attemptTimer?.cancel()
		attemptTimer = nil
		guard phase == .connecting else { return }
		guard !candidates.isEmpty else {
			wait(lastError ?? .posix(.ECONNREFUSED))
			return
		}
		let address = candidates.removeFirst()
		let handle: SocketHandle
		switch makeSocket(family: address.family, parameters: parameters) {
		case .success(let made): handle = made
		case .failure(let error):
			lastError = error
			return tryNextAddress()
		}
		if let error = bindLocal(handle, family: address.family, parameters: parameters) {
			lastError = error
			return tryNextAddress()
		}
		attach(handle)
		let result = address.withSockaddr { connect(handle.fd, $0, $1) }
		if result == 0 {
			connected()
		} else if errno == EINPROGRESS {
			writeWatch.arm(read: false, handle: handle, queue: queue!) { [weak self] in self?.socketEvent() }
			// With more addresses to try, give this one three seconds, as happy eyeballs would.
			if !candidates.isEmpty {
				attemptTimer = timer(after: 3) { [weak self] in
					guard let self = self, self.phase == .connecting else { return }
					self.lastError = .posix(.ETIMEDOUT)
					self.closeSocket()
					self.tryNextAddress()
				}
			}
		} else {
			lastError = .errno()
			closeSocket()
			tryNextAddress()
		}
	}

	private func attach(_ handle: SocketHandle) {
		socket = handle
		locked { _socket = handle }
	}

	private func finishConnect() {
		guard let handle = socket else { return }
		var error: Int32 = 0
		var length = socklen_t(MemoryLayout<Int32>.size)
		getsockopt(handle.fd, SOL_SOCKET, SO_ERROR, &error, &length)
		if error == 0 {
			connected()
		} else {
			lastError = .errno(error)
			closeSocket()
			tryNextAddress()
		}
	}

	private func connected() {
		attemptTimer?.cancel()
		attemptTimer = nil
		writeWatch.disarm()
		guard let tlsOptions = parameters.tlsOptions else {
			becomeReady()
			return
		}
		guard !parameters.isDatagram, let handle = socket else {
			// DTLS is not available.
			fail(.tls(errSSLBadConfiguration))
			return
		}
		var host: String?
		switch endpoint {
		case .hostPort(.name(let name, _), _): host = name
		case .url(let url): host = url.host
		default: host = nil
		}
		var status: Int32 = 0
		guard let session = darling_nw_tls_create(tlsOptions.securityProtocolOptions, handle.fd, host, &status) else {
			fail(.tls(status))
			return
		}
		tls = session
		phase = .handshaking
		handshake()
	}

	private func handshake() {
		guard let tls = tls, let handle = socket else { return }
		let result = darling_nw_tls_handshake(tls)
		switch result {
		case 0:
			readWatch.disarm()
			writeWatch.disarm()
			let generation = self.generation
			darling_nw_tls_verify(tls) { trusted in
				self.queue?.async {
					guard self.phase == .handshaking, self.generation == generation else { return }
					guard trusted else { return self.fail(.tls(errSSLXCertChainInvalid)) }
					let metadata = NWProtocolTLS.Metadata(metadata: darling_nw_tls_copy_metadata(tls))
					self.locked { self._tlsMetadata = metadata }
					self.becomeReady()
				}
			}
		case Int32(_DarlingTLS_WANT_POLLIN):
			writeWatch.disarm()
			readWatch.arm(read: true, handle: handle, queue: queue!) { [weak self] in self?.socketEvent() }
		case Int32(_DarlingTLS_WANT_POLLOUT):
			readWatch.disarm()
			writeWatch.arm(read: false, handle: handle, queue: queue!) { [weak self] in self?.socketEvent() }
		default:
			fail(.tls(result))
		}
	}

	private func becomeReady() {
		connectTimer?.cancel()
		connectTimer = nil
		phase = .ready
		var local: NWEndpoint?, remote: NWEndpoint?
		if let handle = socket {
			local = SocketAddress.of(handle.fd, peer: false)?.endpoint
			remote = SocketAddress.of(handle.fd, peer: true)?.endpoint
		}
		let path = NWPath.current(required: nil, prohibited: []).connected(local: local, remote: remote ?? endpoint)
		let (pathHandler, viabilityHandler): (((NWPath) -> Void)?, ((Bool) -> Void)?) = locked {
			_currentPath = path
			return (_pathUpdateHandler, _viabilityUpdateHandler)
		}
		setState(.ready)
		pathHandler?(path)
		viabilityHandler?(true)
		pump()
	}

	/// No address worked, or none could be found: Network.framework waits for the network to
	/// change. Darling's does not change, so the connection waits for restart() or cancel().
	private func wait(_ error: NWError) {
		closeSocket()
		phase = .waiting
		setState(.waiting(error))
	}

	private func socketEvent() {
		switch phase {
		case .connecting: finishConnect()
		case .handshaking: handshake()
		case .ready: pump()
		default:
			readWatch.disarm()
			writeWatch.disarm()
		}
	}

	private func closeSocket() {
		readWatch.disarm()
		writeWatch.disarm()
		if let tls = tls {
			darling_nw_tls_free(tls)
			self.tls = nil
		}
		socket = nil
		locked { _socket = nil }
	}

	/// Ends the connection: pending sends and receives complete with the reason.
	private func finish(_ state: State) {
		guard phase != .cancelled, phase != .failed || state == .cancelled else { return }
		let error: NWError
		if case .failed(let reason) = state { error = reason } else { error = .posix(.ECANCELED) }
		attemptTimer?.cancel()
		attemptTimer = nil
		connectTimer?.cancel()
		connectTimer = nil
		closeSocket()
		phase = state == .cancelled ? .cancelled : .failed
		let pendingSends = sends, pendingReceives = receives
		sends = []
		receives = []
		for send in pendingSends {
			if case .contentProcessed(let completion) = send.completion { completion(error) }
		}
		for receive in pendingReceives {
			receive.completion(nil, nil, false, error)
		}
		setState(state)
		if state == .cancelled {
			// Network.framework lets go of the handlers once the connection is cancelled, which is
			// what breaks the retain cycles apps build through them.
			locked {
				_stateUpdateHandler = nil
				_pathUpdateHandler = nil
				_viabilityUpdateHandler = nil
				_betterPathUpdateHandler = nil
			}
		}
	}

	private func fail(_ error: NWError) {
		finish(.failed(error))
	}

	// MARK: Sending and receiving

	/// Writes what can be written and reads what the pending receives want, then waits on the
	/// socket for whatever stopped it.
	private func pump() {
		guard phase == .ready, let handle = socket else { return }
		var wantRead = false, wantWrite = false

		while !sends.isEmpty {
			var send = sends[0]
			// A datagram goes out whole, even when empty; a stream writes until the data is done.
			while parameters.isDatagram ? !send.isNil && !send.written : send.offset < send.data.count {
				let result = write(send.data, from: send.offset, fd: handle.fd)
				if result >= 0 {
					send.offset += result
					send.written = true
					sends[0] = send
				} else if result == Int(_DarlingTLS_WANT_POLLOUT) {
					wantWrite = true
					break
				} else if result == Int(_DarlingTLS_WANT_POLLIN) {
					wantRead = true
					break
				} else {
					fail(lastError ?? .posix(.EPIPE))
					return
				}
			}
			if wantRead || wantWrite { break }
			sends.removeFirst()
			if send.isFinal && !parameters.isDatagram && !wroteFinal {
				wroteFinal = true
				// A TLS stream cannot be half-closed; close_notify goes out when it is torn down.
				if tls == nil { shutdown(handle.fd, SHUT_WR) }
			}
			if case .contentProcessed(let completion) = send.completion { completion(nil) }
			guard phase == .ready else { return }
		}

		deliver()
		while !receives.isEmpty && !readEOF && phase == .ready {
			let result = read(fd: handle.fd)
			if result > 0 {
				deliver()
			} else if result == 0 {
				readEOF = true
				deliver()
			} else if result == Int(_DarlingTLS_WANT_POLLIN) {
				wantRead = true
				break
			} else if result == Int(_DarlingTLS_WANT_POLLOUT) {
				wantWrite = true
				break
			} else {
				fail(lastError ?? .posix(.ECONNRESET))
				return
			}
		}
		guard phase == .ready, socket != nil else { return }

		if wantRead {
			readWatch.arm(read: true, handle: handle, queue: queue!) { [weak self] in self?.socketEvent() }
		} else {
			readWatch.disarm()
		}
		if wantWrite {
			writeWatch.arm(read: false, handle: handle, queue: queue!) { [weak self] in self?.socketEvent() }
		} else {
			writeWatch.disarm()
		}
	}

	/// Bytes written, or a TLS_WANT_* value to wait on the socket, or another negative value with
	/// lastError set.
	private func write(_ data: Data, from offset: Int, fd: Int32) -> Int {
		data.withUnsafeBytes { raw -> Int in
			let base = raw.baseAddress.map { $0 + offset } ?? UnsafeRawPointer(bitPattern: 1)!
			let length = data.count - offset
			if let tls = tls {
				let result = darling_nw_tls_write(tls, base, UInt(length))
				if result == -1 { lastError = .tls(errSSLClosedAbort) }
				return result
			}
			let result = Darwin.send(fd, base, length, 0)
			if result >= 0 { return result }
			if errno == EAGAIN || errno == EWOULDBLOCK { return Int(_DarlingTLS_WANT_POLLOUT) }
			lastError = .errno()
			return -1
		}
	}

	/// Bytes read into the inbox (a datagram, for UDP), 0 at the end of the stream, a TLS_WANT_*
	/// value to wait on the socket, or another negative value with lastError set.
	private func read(fd: Int32) -> Int {
		var buffer = [UInt8](repeating: 0, count: 65_536)
		let result: Int = buffer.withUnsafeMutableBytes { raw in
			if let tls = tls {
				let result = darling_nw_tls_read(tls, raw.baseAddress!, UInt(raw.count))
				if result == -1 { lastError = .tls(errSSLClosedAbort) }
				return result
			}
			let result = recv(fd, raw.baseAddress!, raw.count, 0)
			if result >= 0 { return result }
			if errno == EAGAIN || errno == EWOULDBLOCK { return Int(_DarlingTLS_WANT_POLLIN) }
			lastError = .errno()
			return -1
		}
		if result > 0 || (result == 0 && parameters.isDatagram) {
			if parameters.isDatagram {
				datagrams.append(Data(buffer[0..<result]))
				return max(result, 1)
			}
			inboxData.append(contentsOf: buffer[0..<result])
		}
		return result
	}

	/// Completes the receives the inbox can satisfy, in order.
	private func deliver() {
		while let receive = receives.first {
			if parameters.isDatagram {
				guard !datagrams.isEmpty else { return }
				let datagram = datagrams.removeFirst()
				receives.removeFirst()
				receive.completion(datagram.prefix(receive.maximum), .defaultMessage, true, nil)
				continue
			}
			if receive.wholeMessage {
				// A stream's one message ends with the stream.
				guard readEOF else { return }
				let content = inboxData.isEmpty ? nil : inboxData
				inboxData = Data()
				receives.removeFirst()
				receive.completion(content, .finalMessage, true, nil)
				continue
			}
			if inboxData.isEmpty {
				guard readEOF else { return }
				receives.removeFirst()
				receive.completion(nil, .finalMessage, true, nil)
				continue
			}
			guard inboxData.count >= max(receive.minimum, 1) || readEOF else { return }
			let count = min(inboxData.count, receive.maximum)
			let content = Data(inboxData.prefix(count))
			inboxData.removeFirst(count)
			receives.removeFirst()
			let complete = readEOF && inboxData.isEmpty
			receive.completion(content, complete ? .finalMessage : .defaultStream, complete, nil)
		}
	}

	private func enqueue(_ receive: Receive) {
		perform {
			switch self.phase {
			case .failed, .cancelled:
				receive.completion(nil, nil, false, .posix(.ECANCELED))
			default:
				self.receives.append(receive)
				self.pump()
			}
		}
	}

	public final func receive(minimumIncompleteLength: Int, maximumLength: Int,
	                          completion: @escaping (_ content: Data?, _ contentContext: ContentContext?, _ isComplete: Bool, _ error: NWError?) -> Void) {
		enqueue(Receive(minimum: minimumIncompleteLength, maximum: max(maximumLength, 1), wholeMessage: false, completion: completion))
	}

	public final func receiveDiscontiguous(minimumIncompleteLength: Int, maximumLength: Int,
	                                       completion: @escaping (_ content: DispatchData?, _ contentContext: ContentContext?, _ isComplete: Bool, _ error: NWError?) -> Void) {
		receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { content, context, complete, error in
			completion(content.map(NWConnection.dispatchData), context, complete, error)
		}
	}

	public final func receiveMessage(completion: @escaping (_ completeContent: Data?, _ contentContext: ContentContext?, _ isComplete: Bool, _ error: NWError?) -> Void) {
		enqueue(Receive(minimum: 1, maximum: Int.max, wholeMessage: !parameters.isDatagram, completion: completion))
	}

	public final func receiveMessageDiscontiguous(completion: @escaping (_ completeContent: DispatchData?, _ contentContext: ContentContext?, _ isComplete: Bool, _ error: NWError?) -> Void) {
		receiveMessage { content, context, complete, error in
			completion(content.map(NWConnection.dispatchData), context, complete, error)
		}
	}

	private static func dispatchData(_ data: Data) -> DispatchData {
		data.withUnsafeBytes { DispatchData(bytes: $0) }
	}

	public final func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true,
	                       completion: SendCompletion) {
		let send = Send(data: content ?? Data(), isNil: content == nil, isFinal: contentContext.isFinal && isComplete,
		                completion: completion)
		perform {
			switch self.phase {
			case .failed, .cancelled:
				if case .contentProcessed(let completion) = send.completion { completion(.posix(.ECANCELED)) }
			default:
				self.sends.append(send)
				self.pump()
			}
		}
	}

	@usableFromInline
	final internal func send(discontiguousContent: DispatchData, contentContext: ContentContext = .defaultMessage,
	                         isComplete: Bool = true, completion: SendCompletion) {
		send(content: Data(discontiguousContent), contentContext: contentContext, isComplete: isComplete, completion: completion)
	}

	@inlinable final public func send<Content>(content: Content?, contentContext: NWConnection.ContentContext = .defaultMessage, isComplete: Bool = true, completion: NWConnection.SendCompletion) where Content : DataProtocol {
		if let dispatchData = content as? DispatchData {
			send(discontiguousContent: dispatchData, contentContext: contentContext, isComplete: isComplete, completion: completion)
		} else if let data = content as? Data {
			send(content: data, contentContext: contentContext, isComplete: isComplete, completion: completion)
		} else if let content = content {
			send(content: Data(content), contentContext: contentContext, isComplete: isComplete, completion: completion)
		} else {
			send(content: nil, contentContext: contentContext, isComplete: isComplete, completion: completion)
		}
	}

	/// Network.framework coalesces the sends made in the block; here each goes out as it comes.
	public final func batch(_ block: () -> Void) {
		block()
	}

	public final func metadata(definition: NWProtocolDefinition) -> NWProtocolMetadata? {
		switch definition.name {
		case NWProtocolTLS.definition.name: return locked { _tlsMetadata }
		case NWProtocolTCP.definition.name:
			guard !parameters.isDatagram, let handle = locked({ _socket }) else { return nil }
			return NWProtocolTCP.Metadata(fd: handle.fd)
		case NWProtocolUDP.definition.name: return parameters.isDatagram ? NWProtocolUDP.Metadata() : nil
		case NWProtocolIP.definition.name: return NWProtocolIP.Metadata()
		default: return nil
		}
	}
}
