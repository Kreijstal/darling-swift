// Foundation's Combine adapters: NotificationCenter.Publisher, Timer.TimerPublisher and RunLoop's
// Scheduler conformance, with the declarations of Apple's SDK interface (so apps built against it
// link). Adapted from OpenCombine's OpenCombineFoundation (NotificationCenter.swift,
// Timer+Publisher.swift, RunLoop+Scheduler.swift; MIT, Copyright (c) 2019 Sergej Jaskiewicz, see
// ../Combine), which declares them under `OCombine` namespaces: here they are the real names,
// over this overlay's Combine, with NSLock for OpenCombine's private unfair locks. Darling's NSTimer
// declares tolerance as accessor methods and its initializers as nullable.
import Combine

// MARK: - NotificationCenter

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension NotificationCenter {
    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> NotificationCenter.Publisher {
        Publisher(center: self, name: name, object: object)
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension NotificationCenter {
    public struct Publisher: Combine.Publisher {
        public typealias Output = Notification
        public typealias Failure = Never

        public let center: NotificationCenter
        public let name: Notification.Name
        public let object: AnyObject?

        public init(center: NotificationCenter, name: Notification.Name, object: AnyObject? = nil) {
            self.center = center
            self.name = name
            self.object = object
        }

        public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Never, S.Input == Notification {
            subscriber.receive(subscription: _NotificationSubscription(center: center, name: name, object: object, downstream: subscriber))
        }
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension NotificationCenter.Publisher: Equatable {
    public static func == (lhs: NotificationCenter.Publisher, rhs: NotificationCenter.Publisher) -> Bool {
        lhs.center == rhs.center && lhs.name == rhs.name && lhs.object === rhs.object
    }
}

private final class _NotificationSubscription<Downstream: Subscriber>: Subscription
    where Downstream.Input == Notification, Downstream.Failure == Never
{
    private let lock = NSLock()
    private let downstreamLock = NSRecursiveLock()
    private var demand = Subscribers.Demand.none
    private var center: NotificationCenter?
    private var observation: NSObjectProtocol?

    init(center: NotificationCenter, name: Notification.Name, object: AnyObject?, downstream: Downstream) {
        self.center = center
        observation = center.addObserver(forName: name, object: object, queue: nil) { [weak self] notification in
            self?.receive(notification, downstream: downstream)
        }
    }

    private func receive(_ notification: Notification, downstream: Downstream) {
        lock.lock()
        guard demand > 0 else { lock.unlock(); return }
        demand -= 1
        lock.unlock()
        downstreamLock.lock()
        let more = downstream.receive(notification)
        downstreamLock.unlock()
        lock.lock()
        demand += more
        lock.unlock()
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        self.demand += demand
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard let center = center, let observation = observation else { lock.unlock(); return }
        self.center = nil
        self.observation = nil
        lock.unlock()
        center.removeObserver(observation)
    }
}

// MARK: - RunLoop as a Scheduler

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension RunLoop: Scheduler {
    public struct SchedulerTimeType: Strideable, Codable, Hashable, Sendable {
        public var date: Date

        public init(_ date: Date) { self.date = date }

        public func distance(to other: RunLoop.SchedulerTimeType) -> RunLoop.SchedulerTimeType.Stride {
            Stride(date.timeIntervalSinceReferenceDate.distance(to: other.date.timeIntervalSinceReferenceDate))
        }

        public func advanced(by n: RunLoop.SchedulerTimeType.Stride) -> RunLoop.SchedulerTimeType {
            SchedulerTimeType(date + n.magnitude)
        }

        public struct Stride: ExpressibleByFloatLiteral, Comparable, SignedNumeric, Codable, SchedulerTimeIntervalConvertible, Sendable {
            public typealias FloatLiteralType = TimeInterval
            public typealias IntegerLiteralType = TimeInterval
            public typealias Magnitude = TimeInterval

            public var magnitude: TimeInterval
            public var timeInterval: TimeInterval { magnitude }

            public init(integerLiteral value: TimeInterval) { magnitude = value }
            public init(floatLiteral value: TimeInterval) { magnitude = value }
            public init(_ timeInterval: TimeInterval) { magnitude = timeInterval }
            public init?<T>(exactly source: T) where T: BinaryInteger {
                guard let value = TimeInterval(exactly: source) else { return nil }
                magnitude = value
            }

            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude * rhs.magnitude) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude + rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude - rhs.magnitude) }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs.magnitude *= rhs.magnitude }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs.magnitude += rhs.magnitude }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs.magnitude -= rhs.magnitude }
            public static func seconds(_ s: Int) -> Stride { Stride(TimeInterval(s)) }
            public static func seconds(_ s: Double) -> Stride { Stride(s) }
            public static func milliseconds(_ ms: Int) -> Stride { Stride(TimeInterval(ms) / 1_000) }
            public static func microseconds(_ us: Int) -> Stride { Stride(TimeInterval(us) / 1_000_000) }
            public static func nanoseconds(_ ns: Int) -> Stride { Stride(TimeInterval(ns) / 1_000_000_000) }
            public static func == (a: Stride, b: Stride) -> Bool { a.magnitude == b.magnitude }
        }
    }

    public struct SchedulerOptions: Sendable {}

    public func schedule(options: RunLoop.SchedulerOptions?, _ action: @escaping () -> Void) {
        perform(action)
    }

    public func schedule(after date: RunLoop.SchedulerTimeType, tolerance: RunLoop.SchedulerTimeType.Stride,
                         options: RunLoop.SchedulerOptions?, _ action: @escaping () -> Void) {
        let timer = Timer(fire: date.date, interval: 0, repeats: false) { _ in action() }!
        timer.setTolerance(tolerance.timeInterval)
        add(timer, forMode: .default)
    }

    public func schedule(after date: RunLoop.SchedulerTimeType, interval: RunLoop.SchedulerTimeType.Stride,
                         tolerance: RunLoop.SchedulerTimeType.Stride, options: RunLoop.SchedulerOptions?,
                         _ action: @escaping () -> Void) -> any Cancellable {
        let timer = Timer(fire: date.date, interval: interval.timeInterval, repeats: true) { _ in action() }!
        timer.setTolerance(tolerance.timeInterval)
        add(timer, forMode: .default)
        return AnyCancellable { timer.invalidate() }
    }

    public var now: RunLoop.SchedulerTimeType { SchedulerTimeType(Date()) }

    public var minimumTolerance: RunLoop.SchedulerTimeType.Stride { SchedulerTimeType.Stride(0) }
}

// MARK: - Timer

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension Timer {
    public static func publish(every interval: TimeInterval, tolerance: TimeInterval? = nil, on runLoop: RunLoop,
                               in mode: RunLoop.Mode, options: RunLoop.SchedulerOptions? = nil) -> Timer.TimerPublisher {
        TimerPublisher(interval: interval, tolerance: tolerance, runLoop: runLoop, mode: mode, options: options)
    }

    final public class TimerPublisher: ConnectablePublisher {
        public typealias Output = Date
        public typealias Failure = Never

        final public let interval: TimeInterval
        final public let tolerance: TimeInterval?
        final public let runLoop: RunLoop
        final public let mode: RunLoop.Mode
        final public let options: RunLoop.SchedulerOptions?

        private let lock = NSLock()
        private var sides: [CombineIdentifier: (Date) -> Void] = [:]

        public init(interval: TimeInterval, tolerance: TimeInterval? = nil, runLoop: RunLoop, mode: RunLoop.Mode,
                    options: RunLoop.SchedulerOptions? = nil) {
            self.interval = interval
            self.tolerance = tolerance
            self.runLoop = runLoop
            self.mode = mode
            self.options = options
        }

        final public func connect() -> any Cancellable {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.fire() }
            timer.setTolerance(tolerance ?? 0)
            runLoop.add(timer, forMode: mode)
            return AnyCancellable { [weak self] in
                timer.invalidate()
                self?.disconnect(nil)
            }
        }

        final public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Never, S.Input == Date {
            let inner = _TimerSubscription(parent: self, downstream: subscriber)
            lock.lock()
            sides[inner.combineIdentifier] = inner.send
            lock.unlock()
            subscriber.receive(subscription: inner)
        }

        private func fire() {
            lock.lock()
            let targets = Array(sides.values)
            lock.unlock()
            let now = Date()
            for send in targets { send(now) }
        }

        fileprivate func disconnect(_ id: CombineIdentifier?) {
            lock.lock()
            if let id = id { sides[id] = nil } else { sides = [:] }
            lock.unlock()
        }
    }
}

private final class _TimerSubscription<Downstream: Subscriber>: Subscription
    where Downstream.Input == Date, Downstream.Failure == Never
{
    private let lock = NSLock()
    private var downstream: Downstream?
    private var pending = Subscribers.Demand.none
    private weak var parent: Timer.TimerPublisher?

    init(parent: Timer.TimerPublisher, downstream: Downstream) {
        self.parent = parent
        self.downstream = downstream
    }

    func send(_ date: Date) {
        lock.lock()
        guard let downstream = downstream, pending != .none else { lock.unlock(); return }
        pending -= 1
        lock.unlock()
        let more = downstream.receive(date)
        guard more != .none else { return }
        lock.lock()
        pending += more
        lock.unlock()
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        if downstream != nil { pending += demand }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard downstream != nil else { lock.unlock(); return }
        downstream = nil
        lock.unlock()
        parent?.disconnect(combineIdentifier)
    }
}
