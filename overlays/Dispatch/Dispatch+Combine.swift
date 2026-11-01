// DispatchQueue as a Combine Scheduler. Current SDKs declare the conformance in the Dispatch
// overlay, `(extension in Dispatch):__C.OS_dispatch_queue.SchedulerTimeType`, so it is here and
// this overlay imports Combine. Adapted from OpenCombine's OpenCombineDispatch (MIT, see
// ../Combine/LICENSE).
import Combine

extension DispatchQueue: Scheduler {
    public struct SchedulerTimeType: Strideable, Codable, Hashable {
        public var dispatchTime: DispatchTime

        public init(_ time: DispatchTime) { dispatchTime = time }

        public func distance(to other: DispatchQueue.SchedulerTimeType) -> DispatchQueue.SchedulerTimeType.Stride {
            let start = dispatchTime.rawValue, end = other.dispatchTime.rawValue
            return .nanoseconds(end >= start ? Int(clamping: end - start) : -Int(clamping: start - end))
        }

        public func advanced(by n: DispatchQueue.SchedulerTimeType.Stride) -> DispatchQueue.SchedulerTimeType {
            n.magnitude == .max ? .init(.distantFuture) : .init(dispatchTime + n.timeInterval)
        }

        public func hash(into hasher: inout Hasher) { hasher.combine(dispatchTime.rawValue) }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(dispatchTime.uptimeNanoseconds)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            dispatchTime = try DispatchTime(uptimeNanoseconds: container.decode(UInt64.self))
        }

        public struct Stride: SchedulerTimeIntervalConvertible, Comparable, SignedNumeric, ExpressibleByFloatLiteral, Hashable, Codable {
            public typealias FloatLiteralType = Double
            public typealias IntegerLiteralType = Int
            public typealias Magnitude = Int

            public var magnitude: Int

            public var timeInterval: DispatchTimeInterval { .nanoseconds(magnitude) }

            public init(_ timeInterval: DispatchTimeInterval) {
                switch timeInterval {
                case .seconds(let s): self = .seconds(s)
                case .milliseconds(let ms): self = .milliseconds(ms)
                case .microseconds(let us): self = .microseconds(us)
                case .nanoseconds(let ns): self = .nanoseconds(ns)
                case .never: self = .nanoseconds(.max)
                @unknown default: self = .nanoseconds(.max)
                }
            }
            private init(nanoseconds: Int) { magnitude = nanoseconds }

            public init(floatLiteral value: Double) { self = .seconds(value) }
            public init(integerLiteral value: Int) { self = .seconds(value) }
            public init?<T>(exactly source: T) where T: BinaryInteger {
                guard let value = Int(exactly: source) else { return nil }
                self = .seconds(value)
            }

            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { Stride(nanoseconds: lhs.magnitude &* rhs.magnitude) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { Stride(nanoseconds: lhs.magnitude &+ rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { Stride(nanoseconds: lhs.magnitude &- rhs.magnitude) }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs = lhs - rhs }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs = lhs * rhs }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs = lhs + rhs }

            private static func clamped(_ value: Int, _ factor: Int) -> Stride {
                let (product, overflow) = value.multipliedReportingOverflow(by: factor)
                return Stride(nanoseconds: overflow ? (value < 0 ? .min : .max) : product)
            }
            public static func seconds(_ s: Double) -> Stride {
                let ns = s * 1_000_000_000
                if ns >= Double(Int.max) { return Stride(nanoseconds: .max) }
                if ns <= Double(Int.min) { return Stride(nanoseconds: .min) }
                return Stride(nanoseconds: Int(ns))
            }
            public static func seconds(_ s: Int) -> Stride { clamped(s, 1_000_000_000) }
            public static func milliseconds(_ ms: Int) -> Stride { clamped(ms, 1_000_000) }
            public static func microseconds(_ us: Int) -> Stride { clamped(us, 1_000) }
            public static func nanoseconds(_ ns: Int) -> Stride { Stride(nanoseconds: ns) }
        }
    }

    public struct SchedulerOptions {
        public var qos: DispatchQoS
        public var flags: DispatchWorkItemFlags
        public var group: DispatchGroup?
        public init(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], group: DispatchGroup? = nil) {
            self.qos = qos
            self.flags = flags
            self.group = group
        }
    }

    public var minimumTolerance: DispatchQueue.SchedulerTimeType.Stride { .nanoseconds(0) }

    public var now: DispatchQueue.SchedulerTimeType { .init(.now()) }

    public func schedule(options: DispatchQueue.SchedulerOptions?, _ action: @escaping () -> Void) {
        let options = options ?? DispatchQueue.SchedulerOptions()
        async(group: options.group, qos: options.qos, flags: options.flags, execute: action)
    }

    public func schedule(after date: DispatchQueue.SchedulerTimeType, tolerance: DispatchQueue.SchedulerTimeType.Stride,
                         options: DispatchQueue.SchedulerOptions?, _ action: @escaping () -> Void) {
        let options = options ?? DispatchQueue.SchedulerOptions()
        asyncAfter(deadline: date.dispatchTime, qos: options.qos, flags: options.flags, execute: action)
    }

    public func schedule(after date: DispatchQueue.SchedulerTimeType, interval: DispatchQueue.SchedulerTimeType.Stride,
                         tolerance: DispatchQueue.SchedulerTimeType.Stride, options: DispatchQueue.SchedulerOptions?,
                         _ action: @escaping () -> Void) -> Cancellable {
        let options = options ?? DispatchQueue.SchedulerOptions()
        let timer = DispatchSource.makeTimerSource(queue: self)
        timer.setEventHandler(qos: options.qos, flags: options.flags, handler: action)
        timer.schedule(deadline: date.dispatchTime, repeating: interval.timeInterval, leeway: tolerance.timeInterval)
        timer.resume()
        return AnyCancellable(timer.cancel)
    }
}

