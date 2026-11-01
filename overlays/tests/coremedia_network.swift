// Tests the CoreMedia and Network overlays: CMTime and CMTimeRange arithmetic, comparison and
// rounding, and NWPathMonitor reading the host's interfaces. Prints one PASS/FAIL line per check
// and exits nonzero on any failure.
import CoreMedia
import Network
import Darwin

var failures = 0
func check(_ name: String, _ ok: Bool) {
	print("\(ok ? "PASS" : "FAIL") \(name)")
	if !ok { failures += 1 }
}

// CMTime
let half = CMTime(value: 1, timescale: 2)
check("value/timescale and seconds", half.seconds == 0.5 && half.isValid && half.isNumeric && !half.hasBeenRounded)
let exact = CMTime(seconds: 1.5, preferredTimescale: 600)
check("init(seconds:) exact", exact.value == 900 && exact.timescale == 600 && !exact.hasBeenRounded)
let third = CMTime(seconds: 1.0 / 3.0, preferredTimescale: 10)
check("init(seconds:) rounded", third.value == 3 && third.hasBeenRounded && CMTIME_HAS_BEEN_ROUNDED(third))
check("init(seconds:) NaN is invalid", !CMTime(seconds: .nan, preferredTimescale: 600).isValid)
check("init(seconds:) infinity", CMTime(seconds: .infinity, preferredTimescale: 600).isPositiveInfinity
	&& CMTime(seconds: -.infinity, preferredTimescale: 600).isNegativeInfinity)
let sum = CMTime(value: 1, timescale: 3) + CMTime(value: 1, timescale: 2)
check("sum over the common timescale", sum.value == 5 && sum.timescale == 6 && !sum.hasBeenRounded)
let difference = CMTime(value: 1, timescale: 3) - CMTime(value: 1, timescale: 2)
check("difference", difference.value == -1 && difference.timescale == 6 && difference.seconds < 0)
check("equal across timescales", CMTime(value: 1, timescale: 2) == CMTime(value: 2, timescale: 4))
check("ordering", CMTime(value: 1, timescale: 2) < CMTime(value: 2, timescale: 3) && CMTime(value: 2, timescale: 3) >= half)
let invalid = CMTime(value: 0, timescale: 0, flags: [], epoch: 0)
let positiveInfinity = CMTime(seconds: .infinity, preferredTimescale: 1)
let negativeInfinity = CMTime(seconds: -.infinity, preferredTimescale: 1)
let indefinite = CMTime(value: 0, timescale: 0, flags: [.valid, .indefinite], epoch: 0)
check("order of the kinds of time", negativeInfinity < half && half < indefinite && indefinite < positiveInfinity && positiveInfinity < invalid)
check("infinity minus infinity is invalid", !(positiveInfinity + negativeInfinity).isValid && !(positiveInfinity - positiveInfinity).isValid)
check("infinity absorbs", (positiveInfinity + half).isPositiveInfinity && (half - positiveInfinity).isNegativeInfinity)
check("seconds of invalid is NaN", invalid.seconds.isNaN && CMTIME_IS_INVALID(invalid) && CMTIME_IS_INDEFINITE(indefinite))
let tenths = CMTime(value: 1, timescale: 3)
check("convertScale rounding", tenths.convertScale(10, method: .roundHalfAwayFromZero).value == 3
	&& tenths.convertScale(10, method: .roundAwayFromZero).value == 4
	&& tenths.convertScale(10, method: .roundTowardZero).value == 3
	&& CMTime(value: -1, timescale: 3).convertScale(10, method: .roundTowardNegativeInfinity).value == -4
	&& tenths.convertScale(10, method: .default).hasBeenRounded)
check("convertScale exact", half.convertScale(600, method: .default).value == 300 && !half.convertScale(600, method: .default).hasBeenRounded)

// CMTimeRange
let one = CMTime(value: 1, timescale: 1), two = CMTime(value: 2, timescale: 1), three = CMTime(value: 3, timescale: 1), five = CMTime(value: 5, timescale: 1)
let range = CMTimeRange(start: one, end: three)
check("range from start and end", range.duration == two && range.end == three && range.isValid && !range.isEmpty)
check("containsTime", range.containsTime(two) && range.containsTime(one) && !range.containsTime(three))
let later = CMTimeRange(start: two, end: five)
check("intersection", range.intersection(later) == CMTimeRange(start: two, end: three))
check("union", range.union(later) == CMTimeRange(start: one, end: five))
check("containsTimeRange", CMTimeRange(start: one, end: five).containsTimeRange(range) && !range.containsTimeRange(later))
check("empty range", CMTimeRange(start: two, end: two).isEmpty && CMTIMERANGE_IS_EMPTY(CMTimeRange(start: two, end: two)))
check("invalid range", !CMTimeRange(start: three, end: one).isValid && CMTIMERANGE_IS_INVALID(CMTimeRange(start: three, end: one)))
check("range inequality", range != later)

// NWPathMonitor
let monitor = NWPathMonitor()
let path = monitor.currentPath
print("path: \(path.debugDescription), interfaces: \(path.availableInterfaces.map { "\($0.name):\($0.type)" })")
check("path is satisfied", path.status == .satisfied && path.supportsDNS)
if let first = path.availableInterfaces.first {
	check("loopback is not the first interface", first.type != .loopback && path.usesInterfaceType(first.type))
}
let offline = NWPathMonitor(prohibitedInterfaceTypes: [.wifi, .cellular, .wiredEthernet, .other])
check("prohibited interfaces leave the path unsatisfied", offline.currentPath.status == .unsatisfied
	&& offline.currentPath.availableInterfaces.allSatisfy { $0.type == .loopback })
let loopback = NWPathMonitor(requiredInterfaceType: .loopback)
check("required interface type filters", loopback.currentPath.availableInterfaces.allSatisfy { $0.type == .loopback })

var updates = 0
monitor.pathUpdateHandler = { newPath in
	updates += 1
	check("handler gets the current path", newPath == monitor.currentPath)
}
monitor.start(queue: dispatch_queue_create("coremedia_network", nil))
for _ in 0..<50 where updates == 0 { usleep(100_000) }
check("handler called once on start", updates == 1)
usleep(4_500_000)
check("no further updates while nothing changes", updates == 1)
monitor.cancel()

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
