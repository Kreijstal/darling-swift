// Exercises the Network Swift overlay through the iOS SDK's interface, so every call binds to the
// symbol names Apple's libswiftNetwork exports: a listener and connection over loopback, refused
// and resolved connections, UDP, and TLS to a real server through Security's sec_protocol_options.
import Network
import Foundation
import Security

var failures = 0
func check(_ ok: Bool, _ what: String) {
	print((ok ? "ok   " : "FAIL ") + what)
	fflush(stdout)
	if !ok { failures += 1 }
}

let queue = DispatchQueue(label: "nettest")

/// Waits up to `seconds` for `body` to call its completion.
func wait(_ seconds: Double = 10, _ body: (@escaping () -> Void) -> Void) -> Bool {
	let semaphore = DispatchSemaphore(value: 0)
	body { semaphore.signal() }
	return semaphore.wait(timeout: .now() + seconds) == .success
}

// Values
check(IPv4Address("192.168.1.20")?.rawValue == Data([192, 168, 1, 20]), "IPv4Address(string).rawValue")
check(IPv4Address(Data([10, 0, 0, 1]), nil)?.debugDescription == "10.0.0.1", "IPv4Address(data).debugDescription")
check(IPv6Address("::1")?.rawValue == Data([UInt8](repeating: 0, count: 15) + [1]), "IPv6Address(string).rawValue")
check(IPv6Address(Data([0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [5]), nil)?.debugDescription == "fe80::5", "IPv6Address(data).debugDescription")
check(IPv4Address("300.1.1.1") == nil && IPv6Address("nope") == nil, "invalid addresses are nil")
let host: NWEndpoint.Host = "127.0.0.1"
if case .ipv4 = host { check(true, "Host string literal parses an IPv4 address") } else { check(false, "Host string literal parses an IPv4 address") }
if case .name("example.com", nil) = NWEndpoint.Host("example.com") { check(true, "Host(name)") } else { check(false, "Host(name)") }
check(NWEndpoint.Port(rawValue: 8080)?.rawValue == 8080 && NWEndpoint.Port.any.rawValue == 0 && NWEndpoint.Port("https")?.rawValue == 443, "Port")
check(NWEndpoint.hostPort(host: "::1", port: 80) == .hostPort(host: .ipv6(.loopback), port: .http), "NWEndpoint ==")
check(NWError.posix(.ECONNREFUSED) == .posix(.ECONNREFUSED) && NWError.posix(.ECONNREFUSED) != .tls(-9807), "NWError ==")
check(NWProtocolTLS.definition == NWProtocolTLS.definition && !(NWProtocolTCP.definition == NWProtocolTLS.definition), "NWProtocolDefinition ==")

// A listener and a connection to it, echoing.
let tcp = NWProtocolTCP.Options()
tcp.noDelay = true
tcp.enableKeepalive = true
tcp.keepaliveIdle = 30
tcp.connectionTimeout = 5
check(tcp.noDelay && tcp.keepaliveIdle == 30, "NWProtocolTCP.Options properties")
let serverParameters = NWParameters(tls: nil, tcp: tcp)
serverParameters.allowLocalEndpointReuse = true
let listener = try! NWListener(using: serverParameters, on: .any)
var serverConnections: [NWConnection] = []
listener.newConnectionHandler = { connection in
	serverConnections.append(connection)
	connection.start(queue: queue)
	func echo() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
			if let data = data, !data.isEmpty {
				connection.send(content: data, completion: .contentProcessed { _ in })
			}
			if complete || error != nil {
				connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
			} else {
				echo()
			}
		}
	}
	echo()
}
let ready = wait { done in
	listener.stateUpdateHandler = { state in if state == .ready { done() } }
	listener.start(queue: queue)
}
check(ready && listener.state == .ready, "listener becomes ready")
let port = listener.port ?? .any
check(port.rawValue != 0, "listener.port is bound (\(port.rawValue))")

let client = NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: .tcp)
var states: [NWConnection.State] = []
let clientReady = wait { done in
	client.stateUpdateHandler = { state in
		states.append(state)
		if state == .ready { done() }
	}
	client.start(queue: queue)
}
check(clientReady && states.first == .preparing && client.state == .ready, "connection goes preparing, ready")
if case .hostPort(_, let remotePort)? = client.currentPath?.remoteEndpoint {
	check(remotePort == port, "currentPath.remoteEndpoint is the listener")
} else {
	check(false, "currentPath.remoteEndpoint is the listener")
}
check(client.currentPath?.localEndpoint != nil, "currentPath.localEndpoint")
let payload = Data((0..<200_000).map { UInt8($0 % 251) })
var echoed = Data()
var sendError: NWError? = .posix(.EIO)
let echoDone = wait(20) { done in
	client.batch {
		client.send(content: payload, completion: .contentProcessed { error in sendError = error })
		client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
	}
	func read() {
		client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
			if let data = data { echoed.append(data) }
			if complete || error != nil { done() } else { read() }
		}
	}
	read()
}
check(echoDone && sendError == nil, "200 KB sent, completion without error")
check(echoed == payload, "200 KB echoed back intact, then end of stream (\(echoed.count) bytes)")
check(client.metadata(definition: NWProtocolTCP.definition) is NWProtocolTCP.Metadata, "metadata(definition: tcp)")
let cancelled = wait { done in
	client.stateUpdateHandler = { state in if state == .cancelled { done() } }
	client.cancel()
}
check(cancelled, "cancel() ends in .cancelled")

// A refused connection waits with ECONNREFUSED, once the listener has closed its socket.
let listenerCancelled = wait { done in
	listener.stateUpdateHandler = { if $0 == .cancelled { done() } }
	listener.cancel()
}
check(listenerCancelled, "listener cancel() ends in .cancelled")
let refused = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
var refusedState: NWConnection.State?
let refusedDone = wait { done in
	refused.stateUpdateHandler = { state in
		if case .waiting = state { refusedState = state; done() }
		if case .failed = state { refusedState = state; done() }
		if state == .ready { refusedState = state; done() }
	}
	refused.start(queue: queue)
}
check(refusedDone && refusedState == .waiting(.posix(.ECONNREFUSED)), "refused connection waits with ECONNREFUSED (\(String(describing: refusedState)))")
refused.cancel()

// A name to resolve: localhost, against a second listener.
let listener2 = try! NWListener(using: .tcp)
listener2.newConnectionHandler = { $0.start(queue: queue); serverConnections.append($0) }
_ = wait { done in listener2.stateUpdateHandler = { if $0 == .ready { done() } }; listener2.start(queue: queue) }
let named = NWConnection(host: "localhost", port: listener2.port!, using: .tcp)
let namedReady = wait { done in named.stateUpdateHandler = { if $0 == .ready { done() } }; named.start(queue: queue) }
check(namedReady, "connection to localhost resolves and connects")
named.cancel()
listener2.cancel()

// UDP, to a plain socket that answers each datagram.
let udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
var bindAddress = sockaddr_in()
bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
bindAddress.sin_family = sa_family_t(AF_INET)
bindAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
_ = withUnsafePointer(to: &bindAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(udpSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &bindAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(udpSocket, $0, &boundLength) } }
let udpPort = UInt16(bigEndian: bindAddress.sin_port)
DispatchQueue.global().async {
	var buffer = [UInt8](repeating: 0, count: 2048)
	var peer = sockaddr_storage()
	var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
	let count = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udpSocket, &buffer, buffer.count, 0, $0, &peerLength) } }
	if count > 0 {
		let reply = Array(buffer[0..<count].reversed())
		_ = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udpSocket, reply, reply.count, 0, $0, peerLength) } }
	}
}
let udp = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: udpPort)!, using: NWParameters(dtls: nil, udp: NWProtocolUDP.Options()))
var udpReply: Data?
let udpDone = wait { done in
	udp.stateUpdateHandler = { state in
		guard state == .ready else { return }
		udp.send(content: Data("datagram".utf8), completion: .contentProcessed { _ in })
		udp.receiveMessage { data, _, _, _ in udpReply = data; done() }
	}
	udp.start(queue: queue)
}
check(udpDone && udpReply == Data("margatad".utf8), "UDP datagram out and back")
udp.cancel()

// TLS to a real server: ALPN, the app's verify block, an HTTP request.
func tlsGet(host: String, verify: Bool, alpn: [String]) -> (state: NWConnection.State?, response: String, alpn: String?, verified: Bool) {
	let tlsOptions = NWProtocolTLS.Options()
	for name in alpn { sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, name) }
	sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
	var verified = false
	if verify {
		sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, trust, complete in
			verified = sec_trust_copy_ref(trust).takeRetainedValue() as SecTrust? != nil
			complete(true)
		}, queue)
	}
	let connection = NWConnection(host: NWEndpoint.Host(host), port: .https, using: NWParameters(tls: tlsOptions))
	var finalState: NWConnection.State?
	var response = Data()
	var negotiated: String?
	_ = wait(30) { done in
		connection.stateUpdateHandler = { state in
			switch state {
			case .ready:
				finalState = state
				if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
				   let name = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) {
					negotiated = String(cString: name)
				}
				let request = "GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nUser-Agent: darling-nettest\r\n\r\n"
				connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
				func read() {
					connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
						if let data = data { response.append(data) }
						if complete || error != nil || response.count > 4096 { done() } else { read() }
					}
				}
				read()
			case .failed, .waiting:
				finalState = state
				done()
			default: break
			}
		}
		connection.start(queue: queue)
	}
	connection.cancel()
	let firstLine = String(decoding: response.prefix(while: { $0 != 13 }), as: UTF8.self)
	return (finalState, firstLine, negotiated, verified)
}

let plain = tlsGet(host: "example.com", verify: false, alpn: ["http/1.1"])
check(plain.state == .ready && plain.response.hasPrefix("HTTP/1.1 "), "TLS to example.com, system trust: \(plain.response)")
check(plain.alpn == "http/1.1", "ALPN negotiated http/1.1 (\(plain.alpn ?? "none"))")
let custom = tlsGet(host: "www.google.com", verify: true, alpn: ["http/1.1"])
check(custom.state == .ready && custom.verified && custom.response.hasPrefix("HTTP/1.1 "), "TLS with the app's verify block, which got a SecTrust: \(custom.response)")
let bad = tlsGet(host: "self-signed.badssl.com", verify: false, alpn: [])
var badIsTLS = false
if case .failed(.tls)? = bad.state { badIsTLS = true }
if case .waiting(.tls)? = bad.state { badIsTLS = true }
check(badIsTLS, "a self-signed certificate fails with a TLS error (\(String(describing: bad.state)))")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
