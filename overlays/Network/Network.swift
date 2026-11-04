// Network Swift overlay for Darling, written from Apple's public Network framework documentation
// and the declarations in the iOS SDK's Network.swiftinterface, so apps built against that SDK find
// the symbols they import. Apple's overlay wraps the nw_* C API, which Darling's libnetwork only
// stubs; this one is built on BSD sockets and Dispatch instead (Connection.swift, Listener.swift),
// with TLS from libnetwork's libtls session (darling_tls.m). This file has the interfaces and
// path monitoring, which reads the interfaces from getifaddrs.
@_exported import _DarlingNetworkShims
import Darwin
import Dispatch
import Foundation

/// A network interface on the host.
public struct NWInterface: Hashable, CustomDebugStringConvertible {
	public enum InterfaceType {
		case other
		case wifi
		case cellular
		case wiredEthernet
		case loopback
	}

	public let type: InterfaceType
	public let name: String
	public let index: Int

	public var debugDescription: String { name }

	/// The type a Linux interface name stands for. Darling reports the host's interfaces, so
	/// these are Linux and Android names, not Darwin's en0 and pdp_ip0.
	internal static func type(ofInterfaceNamed name: String) -> InterfaceType {
		func starts(_ prefixes: String...) -> Bool { prefixes.contains { name.hasPrefix($0) } }
		if starts("lo") { return .loopback }
		if starts("wlan", "wl", "wifi", "ath", "ra") { return .wifi }
		if starts("rmnet", "ccmni", "pdp", "wwan", "ppp", "v4-rmnet", "seth") { return .cellular }
		if starts("eth", "en", "em", "usb", "rndis") { return .wiredEthernet }
		return .other
	}
}

/// What a path monitor last saw of the network.
public struct NWPath: Equatable, CustomDebugStringConvertible {
	public enum Status {
		case satisfied
		case unsatisfied
		case requiresConnection
	}

	public enum UnsatisfiedReason {
		case notAvailable
		case cellularDenied
		case wifiDenied
		case localNetworkDenied
		case vpnInactive
	}

	public let status: Status
	public let unsatisfiedReason: UnsatisfiedReason
	public let availableInterfaces: [NWInterface]
	public let isExpensive: Bool
	public let isConstrained: Bool
	public let supportsIPv4: Bool
	public let supportsIPv6: Bool
	public let supportsDNS: Bool
	public let localEndpoint: NWEndpoint?
	public let remoteEndpoint: NWEndpoint?
	/// Darling reads no routing table, so no gateway is known.
	public var gateways: [NWEndpoint] { [] }

	internal init(status: Status, unsatisfiedReason: UnsatisfiedReason, availableInterfaces: [NWInterface],
	              isExpensive: Bool, isConstrained: Bool, supportsIPv4: Bool, supportsIPv6: Bool, supportsDNS: Bool,
	              localEndpoint: NWEndpoint? = nil, remoteEndpoint: NWEndpoint? = nil) {
		self.status = status
		self.unsatisfiedReason = unsatisfiedReason
		self.availableInterfaces = availableInterfaces
		self.isExpensive = isExpensive
		self.isConstrained = isConstrained
		self.supportsIPv4 = supportsIPv4
		self.supportsIPv6 = supportsIPv6
		self.supportsDNS = supportsDNS
		self.localEndpoint = localEndpoint
		self.remoteEndpoint = remoteEndpoint
	}

	/// The current path, as a connection between two endpoints uses it.
	internal func connected(local: NWEndpoint?, remote: NWEndpoint?) -> NWPath {
		NWPath(status: .satisfied, unsatisfiedReason: unsatisfiedReason, availableInterfaces: availableInterfaces,
		       isExpensive: isExpensive, isConstrained: isConstrained, supportsIPv4: supportsIPv4,
		       supportsIPv6: supportsIPv6, supportsDNS: supportsDNS, localEndpoint: local, remoteEndpoint: remote)
	}

	public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool {
		availableInterfaces.first?.type == type
	}

	public var debugDescription: String {
		let names = availableInterfaces.map { $0.name }.joined(separator: ", ")
		return "\(status) (\(names))"
	}

	/// The path over the interfaces that are up and have an address, loopback last. When the
	/// host's interfaces cannot be read (Android may refuse an app the netlink socket), the path
	/// is reported satisfied rather than leaving the app believing it is offline.
	internal static func current(required: NWInterface.InterfaceType?, prohibited: [NWInterface.InterfaceType]) -> NWPath {
		var list: UnsafeMutablePointer<_DarlingIfaddrs>?
		guard _DarlingGetifaddrs(&list) == 0 else {
			return NWPath(status: .satisfied, unsatisfiedReason: .notAvailable, availableInterfaces: [], isExpensive: false, isConstrained: false, supportsIPv4: true, supportsIPv6: false, supportsDNS: true)
		}
		defer { _DarlingFreeifaddrs(list) }

		var interfaces: [NWInterface] = []
		var ipv4 = false, ipv6 = false
		var entry = list
		while let current = entry {
			defer { entry = current.pointee.ifa_next }
			let flags = Int(current.pointee.ifa_flags)
			guard flags & _DarlingIFF_UP != 0, flags & _DarlingIFF_RUNNING != 0, let address = current.pointee.ifa_addr else { continue }
			let family = Int(address[1])
			guard family == _DarlingAF_INET || family == _DarlingAF_INET6 else { continue }
			let name = String(cString: current.pointee.ifa_name)
			let type = NWInterface.type(ofInterfaceNamed: name)
			if let required = required, type != required { continue }
			if prohibited.contains(type) { continue }
			if type != .loopback {
				if family == _DarlingAF_INET { ipv4 = true } else { ipv6 = true }
			}
			if !interfaces.contains(where: { $0.name == name }) {
				interfaces.append(NWInterface(type: type, name: name, index: Int(_DarlingIfNameToIndex(current.pointee.ifa_name))))
			}
		}
		interfaces.sort { ($0.type == .loopback ? 1 : 0, $0.index) < ($1.type == .loopback ? 1 : 0, $1.index) }

		let online = interfaces.contains { $0.type != .loopback }
		return NWPath(status: online ? .satisfied : .unsatisfied, unsatisfiedReason: .notAvailable,
			availableInterfaces: interfaces, isExpensive: interfaces.first?.type == .cellular, isConstrained: false,
			supportsIPv4: ipv4, supportsIPv6: ipv6, supportsDNS: online)
	}
}

/// Reads the path again every two seconds on the monitor's queue, for as long as the monitor
/// lives and is not cancelled. Darling has no routing socket to watch for changes.
private final class Poller {
	weak var monitor: NWPathMonitor?
	let queue: DispatchQueue
	var cancelled = false
	var delivered = false

	init(monitor: NWPathMonitor, queue: DispatchQueue) {
		self.monitor = monitor
		self.queue = queue
	}

	func schedule() {
		let fire = { [self] in
			guard !cancelled, let monitor = monitor else { return }
			monitor.update(force: !delivered)
			delivered = true
			schedule()
		}
		if delivered {
			queue.asyncAfter(deadline: .now() + 2, execute: fire)
		} else {
			queue.async(execute: fire)
		}
	}
}

/// Reports the network path, and each change to it, on a queue.
public final class NWPathMonitor {
	private let requiredInterfaceType: NWInterface.InterfaceType?
	private let prohibitedInterfaceTypes: [NWInterface.InterfaceType]
	private var poller: Poller?

	public private(set) var queue: DispatchQueue?
	public var currentPath: NWPath
	public var pathUpdateHandler: ((_ newPath: NWPath) -> Void)?

	public init(requiredInterfaceType: NWInterface.InterfaceType) {
		self.requiredInterfaceType = requiredInterfaceType
		self.prohibitedInterfaceTypes = []
		self.currentPath = NWPath.current(required: requiredInterfaceType, prohibited: [])
	}

	public init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) {
		self.requiredInterfaceType = nil
		self.prohibitedInterfaceTypes = prohibitedInterfaceTypes
		self.currentPath = NWPath.current(required: nil, prohibited: prohibitedInterfaceTypes)
	}

	public init() {
		self.requiredInterfaceType = nil
		self.prohibitedInterfaceTypes = []
		self.currentPath = NWPath.current(required: nil, prohibited: [])
	}

	/// Starts monitoring: the handler gets the current path at once, then every change.
	public func start(queue: DispatchQueue) {
		guard self.queue == nil else { return }
		self.queue = queue
		let poller = Poller(monitor: self, queue: queue)
		self.poller = poller
		poller.schedule()
	}

	public func cancel() {
		poller?.cancelled = true
		poller = nil
	}

	fileprivate func update(force: Bool) {
		let path = NWPath.current(required: requiredInterfaceType, prohibited: prohibitedInterfaceTypes)
		guard force || path != currentPath else { return }
		currentPath = path
		pathUpdateHandler?(path)
	}

	deinit {
		poller?.cancelled = true
	}
}
