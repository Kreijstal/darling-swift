// NWError, the IP address types and NWEndpoint, declared as the iOS SDK's Network.swiftinterface
// declares them.
import Darwin
import Foundation

public enum NWError: Error, CustomDebugStringConvertible, Equatable {
	case posix(POSIXErrorCode)
	/// A DNSServiceErrorType.
	case dns(Int32)
	/// An OSStatus from Security.
	case tls(Int32)

	public var debugDescription: String {
		switch self {
		case .posix(let code): return "POSIXErrorCode(rawValue: \(code.rawValue)): \(String(cString: strerror(code.rawValue)))"
		case .dns(let code): return "DNSServiceErrorType(\(code))"
		case .tls(let status): return "OSStatus(\(status)): TLS failure"
		}
	}

	public static func == (a: NWError, b: NWError) -> Bool {
		switch (a, b) {
		case (.posix(let x), .posix(let y)): return x == y
		case (.dns(let x), .dns(let y)), (.tls(let x), .tls(let y)): return x == y
		default: return false
		}
	}

	internal static func errno(_ value: Int32 = Darwin.errno) -> NWError {
		.posix(POSIXErrorCode(rawValue: value) ?? .EIO)
	}
}

extension NWError: CustomNSError {
	public var errorCode: Int {
		switch self {
		case .posix(let code): return Int(code.rawValue)
		case .dns(let code), .tls(let code): return Int(code)
		}
	}

	public var errorUserInfo: [String: Any] {
		[NSLocalizedDescriptionKey: debugDescription]
	}

	public var _domain: String {
		switch self {
		case .posix: return NSPOSIXErrorDomain
		case .dns: return "kNWErrorDomainDNS"
		case .tls: return "kNWErrorDomainTLS"
		}
	}
}

public protocol IPAddress {
	var rawValue: Data { get }
	init?(_ rawValue: Data, _ interface: NWInterface?)
	init?(_ string: String)
	var interface: NWInterface? { get }
	var isLoopback: Bool { get }
	var isLinkLocal: Bool { get }
	var isMulticast: Bool { get }
}

/// "address%interface" split into its parts, and the interface looked up.
private func splitScope(_ string: String) -> (String, NWInterface?)? {
	guard let percent = string.firstIndex(of: "%") else { return (string, nil) }
	let name = String(string[string.index(after: percent)...])
	guard let interface = NWInterface(named: name) else { return nil }
	return (String(string[..<percent]), interface)
}

public struct IPv4Address: IPAddress, Hashable, CustomDebugStringConvertible {
	/// The address bytes, in network order.
	internal let bytes: [UInt8]
	public let interface: NWInterface?

	internal init(bytes: [UInt8], interface: NWInterface? = nil) {
		self.bytes = bytes
		self.interface = interface
	}

	public static let any = IPv4Address(bytes: [0, 0, 0, 0])
	public static let broadcast = IPv4Address(bytes: [255, 255, 255, 255])
	public static let loopback = IPv4Address(bytes: [127, 0, 0, 1])
	public static let allHostsGroup = IPv4Address(bytes: [224, 0, 0, 1])
	public static let allRoutersGroup = IPv4Address(bytes: [224, 0, 0, 2])
	public static let allReportsGroup = IPv4Address(bytes: [224, 0, 0, 22])
	public static let mdnsGroup = IPv4Address(bytes: [224, 0, 0, 251])

	public var isLoopback: Bool { bytes[0] == 127 }
	public var isLinkLocal: Bool { bytes[0] == 169 && bytes[1] == 254 }
	public var isMulticast: Bool { bytes[0] & 0xF0 == 224 }
	public var rawValue: Data { Data(bytes) }

	public init?(_ rawValue: Data, _ interface: NWInterface? = nil) {
		guard rawValue.count == 4 else { return nil }
		self.init(bytes: [UInt8](rawValue), interface: interface)
	}

	public init?(_ string: String) {
		guard let (address, interface) = splitScope(string) else { return nil }
		var value = in_addr()
		guard inet_pton(AF_INET, address, &value) == 1 else { return nil }
		self.init(bytes: withUnsafeBytes(of: &value) { [UInt8]($0) }, interface: interface)
	}

	public static func == (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
		lhs.bytes == rhs.bytes && lhs.interface == rhs.interface
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(bytes)
		hasher.combine(interface)
	}

	public var debugDescription: String {
		let text = bytes.map(String.init).joined(separator: ".")
		return interface.map { "\(text)%\($0.name)" } ?? text
	}
}

public struct IPv6Address: IPAddress, Hashable, CustomDebugStringConvertible {
	internal let bytes: [UInt8]
	public let interface: NWInterface?

	internal init(bytes: [UInt8], interface: NWInterface? = nil) {
		self.bytes = bytes
		self.interface = interface
	}

	private static func multicast(_ scope: UInt8, _ last: UInt8) -> IPv6Address {
		IPv6Address(bytes: [0xFF, scope] + [UInt8](repeating: 0, count: 13) + [last])
	}

	public static let any = IPv6Address(bytes: [UInt8](repeating: 0, count: 16))
	/// IPv6 has no broadcast address; this is all-nodes on the link (ff02::1), which takes its place.
	public static let broadcast = multicast(0x02, 1)
	public static let loopback = IPv6Address(bytes: [UInt8](repeating: 0, count: 15) + [1])
	public static let nodeLocalNodes = multicast(0x01, 1)
	public static let linkLocalNodes = multicast(0x02, 1)
	public static let linkLocalRouters = multicast(0x02, 2)

	/// A multicast address's scope, the low four bits of its second byte.
	public enum Scope: UInt8 {
		case nodeLocal = 1
		case linkLocal = 2
		case siteLocal = 5
		case organizationLocal = 8
		case global = 14
	}

	public var isAny: Bool { bytes.allSatisfy { $0 == 0 } }
	public var isLoopback: Bool { self == .loopback || bytes == IPv6Address.loopback.bytes }
	/// ::a.b.c.d, other than :: and ::1.
	public var isIPv4Compatabile: Bool {
		bytes[0..<12].allSatisfy { $0 == 0 } && !(bytes[12] == 0 && bytes[13] == 0 && bytes[14] == 0 && bytes[15] <= 1)
	}
	/// ::ffff:a.b.c.d.
	public var isIPv4Mapped: Bool { bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF }
	public var asIPv4: IPv4Address? {
		isIPv4Mapped || isIPv4Compatabile ? IPv4Address(bytes: Array(bytes[12...]), interface: interface) : nil
	}
	public var is6to4: Bool { bytes[0] == 0x20 && bytes[1] == 0x02 }
	public var isLinkLocal: Bool { bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 }
	public var isMulticast: Bool { bytes[0] == 0xFF }
	public var multicastScope: Scope? { isMulticast ? Scope(rawValue: bytes[1] & 0x0F) : nil }
	public var rawValue: Data { Data(bytes) }

	public init?(_ rawValue: Data, _ interface: NWInterface? = nil) {
		guard rawValue.count == 16 else { return nil }
		self.init(bytes: [UInt8](rawValue), interface: interface)
	}

	public init?(_ string: String) {
		var text = string
		if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
		guard let (address, interface) = splitScope(text) else { return nil }
		var value = in6_addr()
		guard inet_pton(AF_INET6, address, &value) == 1 else { return nil }
		self.init(bytes: withUnsafeBytes(of: &value) { [UInt8]($0) }, interface: interface)
	}

	public static func == (lhs: IPv6Address, rhs: IPv6Address) -> Bool {
		lhs.bytes == rhs.bytes && lhs.interface == rhs.interface
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(bytes)
		hasher.combine(interface)
	}

	public var debugDescription: String {
		var value = in6_addr()
		withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
		var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		inet_ntop(AF_INET6, &value, &text, socklen_t(text.count))
		let address = String(cString: text)
		return interface.map { "\(address)%\($0.name)" } ?? address
	}
}

public enum NWEndpoint: Hashable, CustomDebugStringConvertible {
	case hostPort(host: NWEndpoint.Host, port: NWEndpoint.Port)
	case service(name: String, type: String, domain: String, interface: NWInterface?)
	case unix(path: String)
	case url(_: URL)
	case opaque(_: nw_endpoint_t)

	public enum Host: Hashable, CustomDebugStringConvertible, ExpressibleByStringLiteral {
		public typealias StringLiteralType = String

		case name(String, NWInterface?)
		case ipv4(IPv4Address)
		case ipv6(IPv6Address)

		public init(stringLiteral: StringLiteralType) {
			self.init(stringLiteral)
		}

		/// An address when the string is one, otherwise a name to resolve.
		public init(_ string: String) {
			if let address = IPv4Address(string) {
				self = .ipv4(address)
			} else if let address = IPv6Address(string) {
				self = .ipv6(address)
			} else if let (name, interface) = splitScope(string) {
				self = .name(name, interface)
			} else {
				self = .name(string, nil)
			}
		}

		public var interface: NWInterface? {
			switch self {
			case .name(_, let interface): return interface
			case .ipv4(let address): return address.interface
			case .ipv6(let address): return address.interface
			}
		}

		public var debugDescription: String {
			switch self {
			case .name(let name, let interface): return interface.map { "\(name)%\($0.name)" } ?? name
			case .ipv4(let address): return address.debugDescription
			case .ipv6(let address): return address.debugDescription
			}
		}

		public static func == (a: Host, b: Host) -> Bool {
			switch (a, b) {
			case (.name(let x, let i), .name(let y, let j)): return x == y && i == j
			case (.ipv4(let x), .ipv4(let y)): return x == y
			case (.ipv6(let x), .ipv6(let y)): return x == y
			default: return false
			}
		}

		public func hash(into hasher: inout Hasher) {
			switch self {
			case .name(let name, let interface): hasher.combine(0); hasher.combine(name); hasher.combine(interface)
			case .ipv4(let address): hasher.combine(1); hasher.combine(address)
			case .ipv6(let address): hasher.combine(2); hasher.combine(address)
			}
		}
	}

	public struct Port: Hashable, CustomDebugStringConvertible, ExpressibleByIntegerLiteral, RawRepresentable {
		public typealias IntegerLiteralType = UInt16

		private let port: UInt16

		public static let any: Port = 0
		public static let ssh: Port = 22
		public static let smtp: Port = 25
		public static let http: Port = 80
		public static let pop: Port = 110
		public static let imap: Port = 143
		public static let https: Port = 443
		public static let imaps: Port = 993
		public static let socks: Port = 1080

		public var rawValue: UInt16 { port }

		/// A port number, or a service name from the services database.
		public init?(_ service: String) {
			if let number = UInt16(service) {
				port = number
			} else if let entry = getservbyname(service, nil) {
				port = UInt16(bigEndian: UInt16(truncatingIfNeeded: entry.pointee.s_port))
			} else {
				return nil
			}
		}

		public init(integerLiteral value: UInt16) {
			port = value
		}

		public init?(rawValue: UInt16) {
			port = rawValue
		}

		public var debugDescription: String { String(port) }
	}

	public var interface: NWInterface? {
		switch self {
		case .hostPort(let host, _): return host.interface
		case .service(_, _, _, let interface): return interface
		default: return nil
		}
	}

	public static func == (lhs: NWEndpoint, rhs: NWEndpoint) -> Bool {
		switch (lhs, rhs) {
		case (.hostPort(let h1, let p1), .hostPort(let h2, let p2)): return h1 == h2 && p1 == p2
		case (.service(let n1, let t1, let d1, let i1), .service(let n2, let t2, let d2, let i2)):
			return n1 == n2 && t1 == t2 && d1 == d2 && i1 == i2
		case (.unix(let a), .unix(let b)): return a == b
		case (.url(let a), .url(let b)): return a == b
		case (.opaque(let a), .opaque(let b)): return a === b
		default: return false
		}
	}

	public func hash(into hasher: inout Hasher) {
		switch self {
		case .hostPort(let host, let port): hasher.combine(0); hasher.combine(host); hasher.combine(port)
		case .service(let name, let type, let domain, let interface):
			hasher.combine(1); hasher.combine(name); hasher.combine(type); hasher.combine(domain); hasher.combine(interface)
		case .unix(let path): hasher.combine(2); hasher.combine(path)
		case .url(let url): hasher.combine(3); hasher.combine(url)
		case .opaque(let object): hasher.combine(4); hasher.combine(ObjectIdentifier(object))
		}
	}

	public var debugDescription: String {
		switch self {
		case .hostPort(let host, let port):
			if case .ipv6 = host { return "[\(host.debugDescription)]:\(port.debugDescription)" }
			return "\(host.debugDescription):\(port.debugDescription)"
		case .service(let name, let type, let domain, _): return "\(name).\(type)\(domain)"
		case .unix(let path): return path
		case .url(let url): return url.absoluteString
		case .opaque(let object): return "\(object)"
		}
	}
}

extension NWInterface {
	/// The host interface with this name, if there is one.
	internal init?(named name: String) {
		let index = _DarlingIfNameToIndex(name)
		guard index != 0 else { return nil }
		self.init(type: NWInterface.type(ofInterfaceNamed: name), name: name, index: Int(index))
	}
}
