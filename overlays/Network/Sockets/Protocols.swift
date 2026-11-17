// The protocol definitions, options and metadata, and NWParameters, declared as the iOS SDK's
// Network.swiftinterface declares them. The options are what a connection applies to its socket
// (Connection.swift); the class hierarchy and non-final members match Apple's, so apps call them
// through the same dispatch thunks.
import Darwin
import Dispatch
import Foundation

@_objcRuntimeName(_TtC7Network21_NWProtocolDefinition)
public class NWProtocolDefinition: Equatable, CustomDebugStringConvertible {
	public final let name: String

	internal init(name: String) {
		self.name = name
	}

	public static func == (lhs: NWProtocolDefinition, rhs: NWProtocolDefinition) -> Bool {
		lhs.name == rhs.name
	}

	public var debugDescription: String { name }
}

@_objcRuntimeName(_TtC7Network18_NWProtocolOptions)
public class NWProtocolOptions {
	internal var definition: NWProtocolDefinition { fatalError("abstract") }
	internal init() {}
}

@_objcRuntimeName(_TtC7Network19_NWProtocolMetadata)
public class NWProtocolMetadata {
	internal var definition: NWProtocolDefinition { fatalError("abstract") }
	internal init() {}
}

@_objcRuntimeName(_TtC7Network11_NWProtocol)
public class NWProtocol {
	internal init() {}
}

@_objcRuntimeName(_TtC7Network14_NWProtocolUDP)
public class NWProtocolUDP: NWProtocol {
	public static let definition = NWProtocolDefinition(name: "udp")

	@_objcRuntimeName(_TtCC7Network14_NWProtocolUDP7Options)
	public class Options: NWProtocolOptions {
		/// Accepted and ignored: Linux decides UDP checksums itself.
		public var preferNoChecksum = false
		override internal var definition: NWProtocolDefinition { NWProtocolUDP.definition }
		public override init() {}
	}

	@_objcRuntimeName(_TtCC7Network14_NWProtocolUDP8Metadata)
	public class Metadata: NWProtocolMetadata {
		override internal var definition: NWProtocolDefinition { NWProtocolUDP.definition }
		public override init() {}
	}
}

@_objcRuntimeName(_TtC7Network14_NWProtocolTCP)
public class NWProtocolTCP: NWProtocol {
	public static let definition = NWProtocolDefinition(name: "tcp")

	/// The TCP settings a connection applies to its socket. Those Linux has no counterpart for
	/// (noOptions, retransmitFinDrop, disableAckStretching, enableFastOpen, disableECN,
	/// persistTimeout, connectionDropTime) are kept and ignored.
	@_objcRuntimeName(_TtCC7Network14_NWProtocolTCP7Options)
	public class Options: NWProtocolOptions {
		public var noDelay = false
		public var noPush = false
		public var noOptions = false
		public var enableKeepalive = false
		public var keepaliveCount = 0
		public var keepaliveIdle = 0
		public var keepaliveInterval = 0
		public var maximumSegmentSize = 0
		/// Seconds to wait for the connection to be established; 0 waits as long as the system does.
		public var connectionTimeout = 0
		public var persistTimeout = 0
		public var connectionDropTime = 0
		public var retransmitFinDrop = false
		public var disableAckStretching = false
		public var enableFastOpen = false
		public var disableECN = false
		override internal var definition: NWProtocolDefinition { NWProtocolTCP.definition }
		public override init() {}
	}

	@_objcRuntimeName(_TtCC7Network14_NWProtocolTCP8Metadata)
	public class Metadata: NWProtocolMetadata {
		private let fd: Int32

		internal init(fd: Int32) {
			self.fd = fd
		}

		override internal var definition: NWProtocolDefinition { NWProtocolTCP.definition }

		/// Bytes waiting to be read.
		public var availableReceiveBuffer: UInt32 {
			var count: Int32 = 0
			return ioctl(fd, UInt(_DarlingFIONREAD), &count) == 0 ? UInt32(max(count, 0)) : 0
		}

		/// The socket's send buffer size.
		public var availableSendBuffer: UInt32 {
			var size: Int32 = 0
			var length = socklen_t(MemoryLayout<Int32>.size)
			return getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, &length) == 0 ? UInt32(max(size, 0)) : 0
		}
	}
}

@_objcRuntimeName(_TtC7Network13_NWProtocolIP)
public class NWProtocolIP: NWProtocol {
	public static let definition = NWProtocolDefinition(name: "ip")

	@_objcRuntimeName(_TtCC7Network13_NWProtocolIP7Options)
	public class Options: NWProtocolOptions {
		public enum Version {
			case any
			case v4
			case v6
		}

		public var version: Version = .any
		public var hopLimit: UInt8 = 0
		public var useMinimumMTU = false
		public var disableFragmentation = false
		public var shouldCalculateReceiveTime = false

		public enum AddressPreference {
			case `default`
			case temporary
			case stable
		}

		public var localAddressPreference: AddressPreference = .default
		public var disableMulticastLoopback = false
		override internal var definition: NWProtocolDefinition { NWProtocolIP.definition }
	}

	public enum ECN {
		case nonECT
		case ect0
		case ect1
		case ce
	}

	@_objcRuntimeName(_TtCC7Network13_NWProtocolIP8Metadata)
	public class Metadata: NWProtocolMetadata {
		public var ecn: NWProtocolIP.ECN = .nonECT
		public var serviceClass: NWParameters.ServiceClass = .bestEffort
		public var receiveTime: UInt64 { 0 }
		override internal var definition: NWProtocolDefinition { NWProtocolIP.definition }
		public override init() {}
	}
}

@_objcRuntimeName(_TtC7Network14_NWProtocolTLS)
public class NWProtocolTLS: NWProtocol {
	public static let definition = NWProtocolDefinition(name: "tls")

	/// The settings an app makes with Security's sec_protocol_options_* functions; libnetwork
	/// holds them, and reads them when the connection starts its handshake.
	@_objcRuntimeName(_TtCC7Network14_NWProtocolTLS7Options)
	public class Options: NWProtocolOptions {
		private let options: sec_protocol_options_t

		public var securityProtocolOptions: sec_protocol_options_t { options }
		override internal var definition: NWProtocolDefinition { NWProtocolTLS.definition }

		public override init() {
			options = _DarlingNWTLSCreateOptions()
		}
	}

	@_objcRuntimeName(_TtCC7Network14_NWProtocolTLS8Metadata)
	public class Metadata: NWProtocolMetadata {
		private let metadata: sec_protocol_metadata_t

		internal init(metadata: sec_protocol_metadata_t) {
			self.metadata = metadata
		}

		public var securityProtocolMetadata: sec_protocol_metadata_t { metadata }
		override internal var definition: NWProtocolDefinition { NWProtocolTLS.definition }
	}
}

@_objcRuntimeName(_TtC7Network13_NWParameters)
public final class NWParameters: CustomDebugStringConvertible {
	@_objcRuntimeName(_TtCC7Network13_NWParameters13ProtocolStack)
	public class ProtocolStack {
		public var applicationProtocols: [NWProtocolOptions]
		public var transportProtocol: NWProtocolOptions?
		public var internetProtocol: NWProtocolOptions?

		internal init(applicationProtocols: [NWProtocolOptions], transportProtocol: NWProtocolOptions?,
		              internetProtocol: NWProtocolOptions?) {
			self.applicationProtocols = applicationProtocols
			self.transportProtocol = transportProtocol
			self.internetProtocol = internetProtocol
		}
	}

	public enum ServiceClass {
		case bestEffort
		case background
		case interactiveVideo
		case interactiveVoice
		case responsiveData
		case signaling
	}

	public enum MultipathServiceType {
		case disabled
		case handover
		case interactive
		case aggregate
	}

	public enum ExpiredDNSBehavior {
		case systemDefault
		case allow
		case prohibit
	}

	public enum Attribution: Equatable {
		case developer
		case user
	}

	public final let defaultProtocolStack: ProtocolStack

	public final var requiredInterface: NWInterface?
	public final var requiredInterfaceType: NWInterface.InterfaceType = .other
	public final var prohibitedInterfaces: [NWInterface]?
	public final var prohibitedInterfaceTypes: [NWInterface.InterfaceType]?
	public final var prohibitExpensivePaths = false
	public final var prohibitConstrainedPaths = false
	public final var preferNoProxies = false
	/// The address and port to bind to before connecting or listening.
	public final var requiredLocalEndpoint: NWEndpoint?
	/// SO_REUSEADDR and SO_REUSEPORT on the socket.
	public final var allowLocalEndpointReuse = false
	/// A listener accepts loopback connections only.
	public final var acceptLocalOnly = false
	public final var includePeerToPeer = false
	public final var requiresDNSSECValidation = false
	public final var serviceClass: ServiceClass = .bestEffort
	public final var multipathServiceType: MultipathServiceType = .disabled
	public final var allowFastOpen = false
	public final var expiredDNSBehavior: ExpiredDNSBehavior = .systemDefault
	public final var attribution: Attribution = .developer

	internal init(stack: ProtocolStack) {
		defaultProtocolStack = stack
	}

	/// Parameters with no transport: Apple's default, which a connection treats as TCP.
	public init() {
		defaultProtocolStack = ProtocolStack(applicationProtocols: [], transportProtocol: nil,
		                                     internetProtocol: NWProtocolIP.Options())
	}

	public convenience init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = NWProtocolTCP.Options()) {
		self.init(stack: ProtocolStack(applicationProtocols: tls.map { [$0] } ?? [], transportProtocol: tcp,
		                               internetProtocol: NWProtocolIP.Options()))
	}

	/// DTLS is not available: a connection with these parameters fails with a TLS error.
	public convenience init(dtls: NWProtocolTLS.Options?, udp: NWProtocolUDP.Options = NWProtocolUDP.Options()) {
		self.init(stack: ProtocolStack(applicationProtocols: dtls.map { [$0] } ?? [], transportProtocol: udp,
		                               internetProtocol: NWProtocolIP.Options()))
	}

	public final class var tls: NWParameters { NWParameters(tls: NWProtocolTLS.Options()) }
	public final class var dtls: NWParameters { NWParameters(dtls: NWProtocolTLS.Options()) }
	public final class var tcp: NWParameters { NWParameters(tls: nil) }
	public final class var udp: NWParameters { NWParameters(dtls: nil) }

	public final func copy() -> NWParameters {
		let stack = ProtocolStack(applicationProtocols: defaultProtocolStack.applicationProtocols,
		                          transportProtocol: defaultProtocolStack.transportProtocol,
		                          internetProtocol: defaultProtocolStack.internetProtocol)
		let copy = NWParameters(stack: stack)
		copy.requiredInterface = requiredInterface
		copy.requiredInterfaceType = requiredInterfaceType
		copy.prohibitedInterfaces = prohibitedInterfaces
		copy.prohibitedInterfaceTypes = prohibitedInterfaceTypes
		copy.prohibitExpensivePaths = prohibitExpensivePaths
		copy.prohibitConstrainedPaths = prohibitConstrainedPaths
		copy.preferNoProxies = preferNoProxies
		copy.requiredLocalEndpoint = requiredLocalEndpoint
		copy.allowLocalEndpointReuse = allowLocalEndpointReuse
		copy.acceptLocalOnly = acceptLocalOnly
		copy.includePeerToPeer = includePeerToPeer
		copy.requiresDNSSECValidation = requiresDNSSECValidation
		copy.serviceClass = serviceClass
		copy.multipathServiceType = multipathServiceType
		copy.allowFastOpen = allowFastOpen
		copy.expiredDNSBehavior = expiredDNSBehavior
		copy.attribution = attribution
		return copy
	}

	public final var debugDescription: String {
		var parts = defaultProtocolStack.applicationProtocols.map { $0.definition.name }
		parts.append((defaultProtocolStack.transportProtocol?.definition ?? NWProtocolTCP.definition).name)
		return parts.joined(separator: ", ")
	}

	// What a connection or listener needs from the stack.
	internal var isDatagram: Bool { defaultProtocolStack.transportProtocol is NWProtocolUDP.Options }
	internal var tcpOptions: NWProtocolTCP.Options? { defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options }
	internal var tlsOptions: NWProtocolTLS.Options? {
		defaultProtocolStack.applicationProtocols.lazy.compactMap { $0 as? NWProtocolTLS.Options }.first
	}
	internal var ipVersion: NWProtocolIP.Options.Version {
		(defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version ?? .any
	}
}
