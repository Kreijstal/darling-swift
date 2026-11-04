// Socket plumbing shared by NWConnection and NWListener: addresses, name resolution and the
// socket options NWParameters stand for.
import Darwin
import Dispatch
import Foundation

/// A socket descriptor, closed when the last owner lets go of it. The dispatch sources watching
/// it hold it in their cancel handlers, so it stays open until they have stopped.
internal final class SocketHandle {
	let fd: Int32

	init(fd: Int32) {
		self.fd = fd
	}

	deinit {
		close(fd)
	}
}

/// A socket address, in the sockaddr_storage the socket calls take.
internal struct SocketAddress {
	var storage = sockaddr_storage()
	var length: socklen_t = 0

	var family: Int32 { Int32(storage.ss_family) }

	init?(host: NWEndpoint.Host, port: UInt16) {
		switch host {
		case .ipv4(let address): self.init(ipv4: address.bytes, port: port)
		case .ipv6(let address): self.init(ipv6: address.bytes, port: port, scope: UInt32(address.interface?.index ?? 0))
		case .name: return nil
		}
	}

	init(ipv4 bytes: [UInt8], port: UInt16) {
		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = port.bigEndian
		withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
		self.init(copying: &address, length: MemoryLayout<sockaddr_in>.size)
	}

	init(ipv6 bytes: [UInt8], port: UInt16, scope: UInt32 = 0) {
		var address = sockaddr_in6()
		address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
		address.sin6_family = sa_family_t(AF_INET6)
		address.sin6_port = port.bigEndian
		address.sin6_scope_id = scope
		withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
		self.init(copying: &address, length: MemoryLayout<sockaddr_in6>.size)
	}

	init?(unixPath path: String) {
		var address = sockaddr_un()
		let bytes = Array(path.utf8)
		guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
		address.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		self.init(copying: &address, length: MemoryLayout<sockaddr_un>.size)
	}

	init<T>(copying address: UnsafePointer<T>, length: Int) {
		withUnsafeMutableBytes(of: &storage) { storage in
			storage.copyMemory(from: UnsafeRawBufferPointer(start: address, count: min(length, storage.count)))
		}
		self.length = socklen_t(length)
	}

	init() {}

	func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
		withUnsafeBytes(of: storage) { body($0.baseAddress!.assumingMemoryBound(to: sockaddr.self), length) }
	}

	/// The address as an endpoint: a host and port for IP, a path for a Unix socket.
	var endpoint: NWEndpoint? {
		withUnsafeBytes(of: storage) { raw -> NWEndpoint? in
			switch family {
			case AF_INET:
				let address = raw.load(as: sockaddr_in.self)
				let bytes = withUnsafeBytes(of: address.sin_addr) { [UInt8]($0) }
				return .hostPort(host: .ipv4(IPv4Address(bytes: bytes)), port: NWEndpoint.Port(integerLiteral: UInt16(bigEndian: address.sin_port)))
			case AF_INET6:
				let address = raw.load(as: sockaddr_in6.self)
				let bytes = withUnsafeBytes(of: address.sin6_addr) { [UInt8]($0) }
				let ipv6 = IPv6Address(bytes: bytes)
				let host: NWEndpoint.Host = ipv6.isIPv4Mapped ? .ipv4(ipv6.asIPv4!) : .ipv6(ipv6)
				return .hostPort(host: host, port: NWEndpoint.Port(integerLiteral: UInt16(bigEndian: address.sin6_port)))
			case AF_UNIX:
				let path = withUnsafeBytes(of: raw.load(as: sockaddr_un.self).sun_path) { bytes in
					String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
				}
				return .unix(path: path)
			default:
				return nil
			}
		}
	}

	/// The local or remote address of a socket.
	static func of(_ fd: Int32, peer: Bool) -> SocketAddress? {
		var address = SocketAddress()
		var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
		let result = withUnsafeMutableBytes(of: &address.storage) { raw -> Int32 in
			let pointer = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
			return peer ? getpeername(fd, pointer, &length) : getsockname(fd, pointer, &length)
		}
		guard result == 0 else { return nil }
		address.length = length
		return address
	}
}

// DNSServiceErrorType codes (dns_sd.h), for NWError.dns.
private let kDNSServiceErr_Unknown: Int32 = -65537
private let kDNSServiceErr_NoSuchRecord: Int32 = -65554

/// getaddrinfo, which blocks: call it off the connection's queue.
internal func resolve(name: String, port: UInt16, version: NWProtocolIP.Options.Version, datagram: Bool,
                      passive: Bool = false) -> Result<[SocketAddress], NWError> {
	var hints = addrinfo()
	hints.ai_family = version == .v4 ? AF_INET : version == .v6 ? AF_INET6 : AF_UNSPEC
	hints.ai_socktype = datagram ? SOCK_DGRAM : SOCK_STREAM
	if passive { hints.ai_flags = AI_PASSIVE }
	var list: UnsafeMutablePointer<addrinfo>?
	let status = getaddrinfo(name, String(port), &hints, &list)
	guard status == 0 else {
		return .failure(.dns(status == EAI_NONAME ? kDNSServiceErr_NoSuchRecord : kDNSServiceErr_Unknown))
	}
	defer { freeaddrinfo(list) }
	var addresses: [SocketAddress] = []
	var entry = list
	while let current = entry {
		if let address = current.pointee.ai_addr, current.pointee.ai_family == AF_INET || current.pointee.ai_family == AF_INET6 {
			addresses.append(SocketAddress(copying: address, length: Int(current.pointee.ai_addrlen)))
		}
		entry = current.pointee.ai_next
	}
	return addresses.isEmpty ? .failure(.dns(kDNSServiceErr_NoSuchRecord)) : .success(addresses)
}

internal func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
	var value = value
	_ = setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
}

/// A non-blocking socket configured as the parameters ask. Options Linux refuses are skipped.
internal func makeSocket(family: Int32, parameters: NWParameters) -> Result<SocketHandle, NWError> {
	let fd = socket(family, parameters.isDatagram ? SOCK_DGRAM : SOCK_STREAM, 0)
	guard fd >= 0 else { return .failure(.errno()) }
	let handle = SocketHandle(fd: fd)
	_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
	_ = fcntl(fd, F_SETFD, FD_CLOEXEC)
	setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
	if parameters.allowLocalEndpointReuse {
		setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
		setOption(fd, SOL_SOCKET, SO_REUSEPORT, 1)
	}
	if let tcp = parameters.tcpOptions, family != AF_UNIX {
		if tcp.noDelay { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_NODELAY), 1) }
		if tcp.noPush { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_NOPUSH), 1) }
		if tcp.noOptions { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_NOOPT), 1) }
		if tcp.maximumSegmentSize > 0 { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_MAXSEG), Int32(tcp.maximumSegmentSize)) }
		if tcp.enableKeepalive {
			setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
			if tcp.keepaliveIdle > 0 { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_KEEPALIVE), Int32(tcp.keepaliveIdle)) }
			if tcp.keepaliveInterval > 0 { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_KEEPINTVL), Int32(tcp.keepaliveInterval)) }
			if tcp.keepaliveCount > 0 { setOption(fd, IPPROTO_TCP, Int32(_DarlingTCP_KEEPCNT), Int32(tcp.keepaliveCount)) }
		}
	}
	return .success(handle)
}

/// Binds the socket to the parameters' required local endpoint, when they name one.
internal func bindLocal(_ handle: SocketHandle, family: Int32, parameters: NWParameters) -> NWError? {
	guard case .hostPort(let host, let port)? = parameters.requiredLocalEndpoint else { return nil }
	var address: SocketAddress?
	switch host {
	case .name(let name, _):
		if case .success(let addresses) = resolve(name: name, port: port.rawValue, version: parameters.ipVersion,
		                                          datagram: parameters.isDatagram, passive: true) {
			address = addresses.first { $0.family == family } ?? addresses.first
		}
	default:
		address = SocketAddress(host: host, port: port.rawValue)
	}
	guard var local = address else { return .posix(.EADDRNOTAVAIL) }
	// An IPv4 address on an IPv6 socket binds as its mapped form.
	if family == AF_INET6 && local.family == AF_INET, case .hostPort(.ipv4(let v4), let p)? = local.endpoint {
		local = SocketAddress(ipv6: [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + v4.bytes, port: p.rawValue)
	}
	let result = local.withSockaddr { bind(handle.fd, $0, $1) }
	return result == 0 ? nil : .errno()
}

/// A dispatch source over a socket, created on demand and cancelled when no longer wanted.
internal struct SocketWatch {
	private var source: DispatchSourceProtocol?

	var isArmed: Bool { source != nil }

	mutating func arm(read: Bool, handle: SocketHandle, queue: DispatchQueue, handler: @escaping () -> Void) {
		guard source == nil else { return }
		let source: DispatchSourceProtocol = read
			? DispatchSource.makeReadSource(fileDescriptor: handle.fd, queue: queue)
			: DispatchSource.makeWriteSource(fileDescriptor: handle.fd, queue: queue)
		source.setEventHandler(handler: handler)
		source.setCancelHandler { _ = handle }
		source.resume()
		self.source = source
	}

	mutating func disarm() {
		source?.cancel()
		source = nil
	}
}
