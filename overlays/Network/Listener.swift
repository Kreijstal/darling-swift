// NWListener over a listening BSD socket: each accepted socket becomes an NWConnection, ready
// once the app starts it. TCP only: Darling has no TLS server side and no UDP listener, and a
// service is recorded but not advertised (there is no Bonjour daemon).
import Darwin
import Dispatch
import Foundation

@_objcRuntimeName(_TtC7Network11_NWListener)
public final class NWListener: CustomDebugStringConvertible {
	public struct Service: Equatable, CustomDebugStringConvertible {
		public let name: String?
		public let type: String
		public let domain: String?
		public let txtRecord: Data?
		public var noAutoRename = false

		public init(name: String? = nil, type: String, domain: String? = nil, txtRecord: Data? = nil) {
			self.name = name
			self.type = type
			self.domain = domain
			self.txtRecord = txtRecord
		}

		public var debugDescription: String { "\(name ?? "<default>").\(type).\(domain ?? "local.")" }
	}

	public enum State: Equatable {
		case setup
		case waiting(NWError)
		case ready
		case failed(NWError)
		case cancelled

		public static func == (a: State, b: State) -> Bool {
			switch (a, b) {
			case (.setup, .setup), (.ready, .ready), (.cancelled, .cancelled): return true
			case (.waiting(let x), .waiting(let y)), (.failed(let x), .failed(let y)): return x == y
			default: return false
			}
		}
	}

	public enum ServiceRegistrationChange {
		case add(NWEndpoint)
		case remove(NWEndpoint)
	}

	public static let InfiniteConnectionLimit = -1

	public final let parameters: NWParameters

	private let requestedPort: NWEndpoint.Port
	private let lock = NSLock()
	private var _queue: DispatchQueue?
	private var _state: State = .setup
	private var _stateUpdateHandler: ((State) -> Void)?
	private var _newConnectionHandler: ((NWConnection) -> Void)?
	private var _serviceRegistrationUpdateHandler: ((ServiceRegistrationChange) -> Void)?
	private var _service: Service?
	private var _newConnectionLimit = NWListener.InfiniteConnectionLimit
	private var _port: NWEndpoint.Port?

	// The queue's alone.
	private var socket: SocketHandle?
	private var acceptWatch = SocketWatch()
	private var finished = false

	public init(using: NWParameters, on: NWEndpoint.Port = .any) throws {
		parameters = using
		requestedPort = on
	}

	public convenience init(service: Service, using parameters: NWParameters) throws {
		try self.init(using: parameters, on: .any)
		self.service = service
	}

	private func locked<T>(_ body: () -> T) -> T {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}

	public final var debugDescription: String { "[L] \(parameters.debugDescription) port \(port?.debugDescription ?? "-")" }

	public final var newConnectionHandler: ((_ connection: NWConnection) -> Void)? {
		get { locked { _newConnectionHandler } }
		set { locked { _newConnectionHandler = newValue } }
	}

	public final var state: State { locked { _state } }

	public final var stateUpdateHandler: ((_ newState: State) -> Void)? {
		get { locked { _stateUpdateHandler } }
		set { locked { _stateUpdateHandler = newValue } }
	}

	public final var service: Service? {
		get { locked { _service } }
		set { locked { _service = newValue } }
	}

	/// How many more connections to deliver; at 0 the listener stops accepting until it is raised.
	public final var newConnectionLimit: Int {
		get { locked { _newConnectionLimit } }
		set {
			locked { _newConnectionLimit = newValue }
			if let queue = queue { queue.async { self.acceptConnections() } }
		}
	}

	/// The bound port, once the listener is ready.
	public final var port: NWEndpoint.Port? { locked { _port } }

	public final var serviceRegistrationUpdateHandler: ((_ change: ServiceRegistrationChange) -> Void)? {
		get { locked { _serviceRegistrationUpdateHandler } }
		set { locked { _serviceRegistrationUpdateHandler = newValue } }
	}

	public final var queue: DispatchQueue? { locked { _queue } }

	public final func start(queue: DispatchQueue) {
		let started: Bool = locked {
			guard _queue == nil else { return false }
			_queue = queue
			return true
		}
		if started { queue.async { self.listen() } }
	}

	public final func cancel() {
		guard let queue = queue else {
			locked { _state = .cancelled }
			return
		}
		queue.async { self.finish(.cancelled) }
	}

	private func setState(_ state: State) {
		let handler: ((State) -> Void)? = locked {
			_state = state
			return _stateUpdateHandler
		}
		handler?(state)
	}

	private func finish(_ state: State) {
		guard !finished else { return }
		finished = true
		acceptWatch.disarm()
		socket = nil
		setState(state)
		if state == .cancelled {
			locked {
				_stateUpdateHandler = nil
				_newConnectionHandler = nil
				_serviceRegistrationUpdateHandler = nil
			}
		}
	}

	private func listen() {
		guard !finished else { return }
		if parameters.isDatagram { return finish(.failed(.posix(.ENOTSUP))) }
		// Darling has no TLS server side.
		if parameters.tlsOptions != nil { return finish(.failed(.tls(-9848))) }

		// Dual-stack IPv6 unless IPv4 is asked for, falling back to IPv4 where IPv6 is missing.
		let version = parameters.ipVersion
		var families: [Int32] = version == .v4 ? [AF_INET] : version == .v6 ? [AF_INET6] : [AF_INET6, AF_INET]
		if parameters.acceptLocalOnly && version != .v6 { families = [AF_INET] }
		var lastError: NWError = .posix(.EAFNOSUPPORT)
		for family in families {
			let handle: SocketHandle
			switch makeSocket(family: family, parameters: parameters) {
			case .success(let made): handle = made
			case .failure(let error):
				lastError = error
				continue
			}
			setOption(handle.fd, SOL_SOCKET, SO_REUSEADDR, 1)
			if family == AF_INET6 { setOption(handle.fd, IPPROTO_IPV6, IPV6_V6ONLY, version == .v6 ? 1 : 0) }
			let bound: NWError?
			if parameters.requiredLocalEndpoint != nil {
				bound = bindLocal(handle, family: family, parameters: parameters)
			} else {
				let loopback = parameters.acceptLocalOnly
				let address = family == AF_INET
					? SocketAddress(ipv4: loopback ? [127, 0, 0, 1] : [0, 0, 0, 0], port: requestedPort.rawValue)
					: SocketAddress(ipv6: loopback ? IPv6Address.loopback.bytes : IPv6Address.any.bytes, port: requestedPort.rawValue)
				bound = address.withSockaddr { bind(handle.fd, $0, $1) } == 0 ? nil : .errno()
			}
			if let error = bound {
				lastError = error
				// A port in use is the app's to handle; a missing address family is not.
				if case .posix(.EADDRINUSE) = error { break }
				continue
			}
			guard Darwin.listen(handle.fd, 128) == 0 else {
				lastError = .errno()
				continue
			}
			socket = handle
			if case .hostPort(_, let port)? = SocketAddress.of(handle.fd, peer: false)?.endpoint {
				locked { _port = port }
			}
			acceptWatch.arm(read: true, handle: handle, queue: queue!) { [weak self] in self?.acceptConnections() }
			setState(.ready)
			return
		}
		finish(.failed(lastError))
	}

	private func acceptConnections() {
		guard !finished, let handle = socket else { return }
		while true {
			let limit = locked { _newConnectionLimit }
			guard limit != 0 else {
				acceptWatch.disarm()
				return
			}
			var address = SocketAddress()
			var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
			let fd = withUnsafeMutableBytes(of: &address.storage) { raw in
				accept(handle.fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), &length)
			}
			guard fd >= 0 else {
				if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED {
					finish(.failed(.errno()))
				} else if !acceptWatch.isArmed {
					acceptWatch.arm(read: true, handle: handle, queue: queue!) { [weak self] in self?.acceptConnections() }
				}
				return
			}
			address.length = length
			let accepted = SocketHandle(fd: fd)
			// Linux does not pass O_NONBLOCK on to accepted sockets.
			_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
			setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
			if let tcp = parameters.tcpOptions, tcp.noDelay { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_NODELAY), 1) }
			let remote = address.endpoint ?? .hostPort(host: .ipv4(.any), port: .any)
			let handler: ((NWConnection) -> Void)? = locked {
				if _newConnectionLimit > 0 { _newConnectionLimit -= 1 }
				return _newConnectionHandler
			}
			guard let deliver = handler else { continue }
			deliver(NWConnection(accepted: accepted, remote: remote, parameters: parameters.copy()))
		}
	}
}
