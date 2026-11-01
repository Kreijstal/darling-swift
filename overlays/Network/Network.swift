// Network Swift overlay for Darling, written from Apple's public Network framework documentation
// and the symbol names apps built against the iOS SDK import. Apple's NWPathMonitor wraps the
// nw_path C API, which Darling's Network framework does not implement; this one reads the
// interfaces from getifaddrs instead. Only path monitoring is provided: no NWConnection,
// NWListener or NWEndpoint.
@_exported import _DarlingNetworkShims

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
	fileprivate static func type(ofInterfaceNamed name: String) -> InterfaceType {
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
	fileprivate static func current(required: NWInterface.InterfaceType?, prohibited: [NWInterface.InterfaceType]) -> NWPath {
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
	let queue: OS_dispatch_queue
	var cancelled = false
	var delivered = false

	init(monitor: NWPathMonitor, queue: OS_dispatch_queue) {
		self.monitor = monitor
		self.queue = queue
	}

	func schedule() {
		let context = Unmanaged.passRetained(self).toOpaque()
		if delivered {
			dispatch_after_f(dispatch_time(0, 2_000_000_000), queue, context, pollerFired)
		} else {
			dispatch_async_f(queue, context, pollerFired)
		}
	}
}

private let pollerFired: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
	let poller = Unmanaged<Poller>.fromOpaque(context!).takeRetainedValue()
	guard !poller.cancelled, let monitor = poller.monitor else { return }
	monitor.update(force: !poller.delivered)
	poller.delivered = true
	poller.schedule()
}

/// Reports the network path, and each change to it, on a queue.
public final class NWPathMonitor {
	private let requiredInterfaceType: NWInterface.InterfaceType?
	private let prohibitedInterfaceTypes: [NWInterface.InterfaceType]
	private var poller: Poller?

	public private(set) var queue: OS_dispatch_queue?
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
	public func start(queue: OS_dispatch_queue) {
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
