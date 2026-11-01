// CoreMedia Swift overlay for Darling, written from Apple's public CMTime and CMTimeRange
// documentation and the symbol names apps built against the iOS SDK import. Darling's CoreMedia C
// functions are generated stubs, so the arithmetic is done here in Swift rather than by calling
// CMTimeAdd, CMTimeCompare and the others.
@_exported import _DarlingCoreMediaShims

private let invalidTime = CMTime(value: 0, timescale: 0, flags: [], epoch: 0)
private let zeroTime = CMTime(value: 0, timescale: 1, flags: .valid, epoch: 0)
private let positiveInfinityTime = CMTime(value: 0, timescale: 0, flags: [.valid, .positiveInfinity], epoch: 0)
private let negativeInfinityTime = CMTime(value: 0, timescale: 0, flags: [.valid, .negativeInfinity], epoch: 0)
private let indefiniteTime = CMTime(value: 0, timescale: 0, flags: [.valid, .indefinite], epoch: 0)

/// `numerator / denominator` rounded as `method` says, or nil if it does not fit an Int64.
/// `coarser` tells the QuickTime method whether the timescale is getting smaller.
private func divide(_ numerator: Int128, _ denominator: Int128, _ method: CMTimeRoundingMethod, coarser: Bool) -> (value: Int64, exact: Bool)? {
	var quotient = numerator / denominator
	let remainder = numerator % denominator
	if remainder != 0 {
		let away: Int128 = (numerator < 0) != (denominator < 0) ? -1 : 1
		switch method {
		case .roundTowardZero:
			break
		case .roundAwayFromZero:
			quotient += away
		case .roundTowardPositiveInfinity:
			if away > 0 { quotient += 1 }
		case .roundTowardNegativeInfinity:
			if away < 0 { quotient -= 1 }
		case .quickTime where coarser:
			break
		default:
			if 2 * remainder.magnitude >= denominator.magnitude { quotient += away }
		}
	}
	guard let value = Int64(exactly: quotient) else { return nil }
	return (value, remainder == 0)
}

/// `time`, a numeric time, in `timescale`; infinite with the value's sign when it overflows.
private func rescale(_ time: CMTime, to timescale: CMTimeScale, _ method: CMTimeRoundingMethod) -> CMTime {
	if time.timescale == timescale { return time }
	guard let (value, exact) = divide(Int128(time.value) * Int128(timescale), Int128(time.timescale), method, coarser: timescale < time.timescale) else {
		return time.value < 0 ? negativeInfinityTime : positiveInfinityTime
	}
	var flags = time.flags
	if !exact { flags.insert(.hasBeenRounded) }
	return CMTime(value: value, timescale: timescale, flags: flags, epoch: time.epoch)
}

/// Where a time sorts among the kinds of time: negative infinity, numeric, indefinite, positive
/// infinity, then invalid, as CMTimeCompare documents.
private func rank(_ time: CMTime) -> Int {
	if !time.flags.contains(.valid) { return 4 }
	if time.flags.contains(.positiveInfinity) { return 3 }
	if time.flags.contains(.indefinite) { return 2 }
	if time.flags.contains(.negativeInfinity) { return 0 }
	return 1
}

private func compare(_ a: CMTime, _ b: CMTime) -> Int {
	let ra = rank(a), rb = rank(b)
	if ra != rb { return ra < rb ? -1 : 1 }
	if ra != 1 { return 0 }
	if a.epoch != b.epoch { return a.epoch < b.epoch ? -1 : 1 }
	let left = Int128(a.value) * Int128(b.timescale), right = Int128(b.value) * Int128(a.timescale)
	return left == right ? 0 : (left < right ? -1 : 1)
}

private func gcd(_ a: Int64, _ b: Int64) -> Int64 {
	var (a, b) = (a, b)
	while b != 0 { (a, b) = (b, a % b) }
	return a
}

private func add(_ a: CMTime, _ b: CMTime) -> CMTime {
	if !a.isValid || !b.isValid { return invalidTime }
	if a.isIndefinite || b.isIndefinite { return indefiniteTime }
	if (a.isPositiveInfinity && b.isNegativeInfinity) || (a.isNegativeInfinity && b.isPositiveInfinity) { return invalidTime }
	if a.isPositiveInfinity || b.isPositiveInfinity { return positiveInfinityTime }
	if a.isNegativeInfinity || b.isNegativeInfinity { return negativeInfinityTime }
	if a.epoch != b.epoch { return invalidTime }
	// The least common multiple of the timescales keeps the sum exact; when it does not fit, the
	// finer of the two is used and the sum is rounded.
	var timescale = a.timescale
	if a.timescale != b.timescale {
		let lcm = Int64(a.timescale) / gcd(Int64(a.timescale), Int64(b.timescale)) * Int64(b.timescale)
		timescale = CMTimeScale(exactly: lcm) ?? max(a.timescale, b.timescale)
	}
	let x = rescale(a, to: timescale, .default), y = rescale(b, to: timescale, .default)
	if !x.isNumeric { return x }
	if !y.isNumeric { return y }
	let (value, overflow) = x.value.addingReportingOverflow(y.value)
	if overflow { return x.value < 0 ? negativeInfinityTime : positiveInfinityTime }
	return CMTime(value: value, timescale: timescale, flags: x.flags.union(y.flags), epoch: a.epoch)
}

private func negate(_ time: CMTime) -> CMTime {
	if time.isPositiveInfinity { return negativeInfinityTime }
	if time.isNegativeInfinity { return positiveInfinityTime }
	if !time.isNumeric { return time }
	if time.value == .min { return positiveInfinityTime }
	return CMTime(value: -time.value, timescale: time.timescale, flags: time.flags, epoch: time.epoch)
}

extension CMTime {
	public init(value: CMTimeValue, timescale: CMTimeScale) {
		self.init(value: value, timescale: timescale, flags: .valid, epoch: 0)
	}

	/// The time closest to `seconds` in `preferredTimescale`; a coarser timescale when the value
	/// would not fit, as CMTimeMakeWithSeconds does.
	public init(seconds: Double, preferredTimescale: CMTimeScale) {
		if seconds.isNaN || preferredTimescale <= 0 {
			self = invalidTime
			return
		}
		if seconds.isInfinite {
			self = seconds < 0 ? negativeInfinityTime : positiveInfinityTime
			return
		}
		var timescale = preferredTimescale
		while timescale > 1 && (seconds * Double(timescale)).magnitude >= 0x1p63 { timescale /= 2 }
		let scaled = seconds * Double(timescale)
		guard scaled.magnitude < 0x1p63 else {
			self = seconds < 0 ? negativeInfinityTime : positiveInfinityTime
			return
		}
		let value = scaled.rounded(.toNearestOrAwayFromZero)
		self.init(value: Int64(value), timescale: timescale, flags: value == scaled ? .valid : [.valid, .hasBeenRounded], epoch: 0)
	}

	public var isValid: Bool { flags.contains(.valid) }
	public var isPositiveInfinity: Bool { isValid && flags.contains(.positiveInfinity) }
	public var isNegativeInfinity: Bool { isValid && flags.contains(.negativeInfinity) }
	public var isIndefinite: Bool { isValid && flags.contains(.indefinite) }
	public var isNumeric: Bool { isValid && flags.isDisjoint(with: .impliedValueFlagsMask) }
	public var hasBeenRounded: Bool { isNumeric && flags.contains(.hasBeenRounded) }

	public var seconds: Double {
		if isNumeric && timescale != 0 { return Double(value) / Double(timescale) }
		if isPositiveInfinity { return .infinity }
		if isNegativeInfinity { return -.infinity }
		return .nan
	}

	public func convertScale(_ newTimescale: Int32, method: CMTimeRoundingMethod) -> CMTime {
		if !isNumeric { return self }
		if newTimescale <= 0 { return invalidTime }
		return rescale(self, to: newTimescale, method)
	}
}

extension CMTime: Equatable, Comparable {
	public static func + (left: CMTime, right: CMTime) -> CMTime { add(left, right) }
	public static func - (minuend: CMTime, subtrahend: CMTime) -> CMTime { add(minuend, negate(subtrahend)) }
	public static func < (left: CMTime, right: CMTime) -> Bool { compare(left, right) < 0 }
	public static func <= (left: CMTime, right: CMTime) -> Bool { compare(left, right) <= 0 }
	public static func > (left: CMTime, right: CMTime) -> Bool { compare(left, right) > 0 }
	public static func >= (left: CMTime, right: CMTime) -> Bool { compare(left, right) >= 0 }
	public static func == (time1: CMTime, time2: CMTime) -> Bool { compare(time1, time2) == 0 }
	public static func != (time1: CMTime, time2: CMTime) -> Bool { compare(time1, time2) != 0 }
}

extension CMTimeRange {
	public init(start: CMTime, end: CMTime) {
		self.init(start: start, duration: end - start)
	}

	public var isValid: Bool { start.isValid && duration.isValid && duration.epoch == 0 && duration.value >= 0 }
	public var isIndefinite: Bool { isValid && (start.isIndefinite || duration.isIndefinite) }
	public var isEmpty: Bool { isValid && duration == zeroTime }
	public var end: CMTime { isValid ? start + duration : invalidTime }

	public func union(_ otherRange: CMTimeRange) -> CMTimeRange {
		CMTimeRange(start: min(start, otherRange.start), end: max(end, otherRange.end))
	}

	/// The overlap of the two ranges, or an empty range at zero when they do not overlap.
	public func intersection(_ otherRange: CMTimeRange) -> CMTimeRange {
		let s = max(start, otherRange.start), e = min(end, otherRange.end)
		if e < s { return CMTimeRange(start: zeroTime, duration: zeroTime) }
		return CMTimeRange(start: s, end: e)
	}

	public func containsTime(_ time: CMTime) -> Bool {
		isValid && time.isValid && time >= start && time < end
	}

	public func containsTimeRange(_ range: CMTimeRange) -> Bool {
		isValid && range.isValid && range.start >= start && range.end <= end
	}
}

extension CMTimeRange: Equatable {
	public static func == (range1: CMTimeRange, range2: CMTimeRange) -> Bool {
		range1.start == range2.start && range1.duration == range2.duration
	}

	public static func != (range1: CMTimeRange, range2: CMTimeRange) -> Bool { !(range1 == range2) }
}

public func CMTIME_IS_VALID(_ time: CMTime) -> Bool { time.isValid }
public func CMTIME_IS_INVALID(_ time: CMTime) -> Bool { !time.isValid }
public func CMTIME_IS_POSITIVEINFINITY(_ time: CMTime) -> Bool { time.isPositiveInfinity }
public func CMTIME_IS_NEGATIVEINFINITY(_ time: CMTime) -> Bool { time.isNegativeInfinity }
public func CMTIME_IS_INDEFINITE(_ time: CMTime) -> Bool { time.isIndefinite }
public func CMTIME_IS_NUMERIC(_ time: CMTime) -> Bool { time.isNumeric }
public func CMTIME_HAS_BEEN_ROUNDED(_ time: CMTime) -> Bool { time.hasBeenRounded }
public func CMTIMERANGE_IS_VALID(_ range: CMTimeRange) -> Bool { range.isValid }
public func CMTIMERANGE_IS_INVALID(_ range: CMTimeRange) -> Bool { !range.isValid }
public func CMTIMERANGE_IS_INDEFINITE(_ range: CMTimeRange) -> Bool { range.isIndefinite }
public func CMTIMERANGE_IS_EMPTY(_ range: CMTimeRange) -> Bool { range.isEmpty }
