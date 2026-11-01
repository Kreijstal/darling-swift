// Parts of Apple's Combine that OpenCombine leaves out or declares under other names, with the
// declarations of the iOS SDK's Combine interface so apps built against it link:
// CombineLatest/CombineLatest3, Merge3, Publisher.merge(with:) for publishers of one type, and
// Result.Publisher. (DispatchQueue's Scheduler conformance is in the Dispatch overlay, where
// current SDKs declare it.)

// MARK: - CombineLatest

/// Collects the latest value of each upstream and sends the combination once all have produced one.
/// Upstream demand is unlimited; values are buffered as one combination for the downstream's demand.
private final class _CombineLatestInner<Downstream: Subscriber, Failure>: Subscription, Cancellable where Downstream.Failure == Failure {
    private let lock = UnfairRecursiveLock.allocate()
    private var downstream: Downstream?
    private var latest: [Any?]
    private var finished: [Bool]
    private var subscriptions: [Subscription?]
    private var demand = Subscribers.Demand.none
    private var pending = false
    private let combine: ([Any]) -> Downstream.Input

    init(downstream: Downstream, count: Int, combine: @escaping ([Any]) -> Downstream.Input) {
        self.downstream = downstream
        latest = Array(repeating: nil, count: count)
        finished = Array(repeating: false, count: count)
        subscriptions = Array(repeating: nil, count: count)
        self.combine = combine
    }

    func subscriber<Input>(_ index: Int, _ type: Input.Type) -> AnySubscriber<Input, Failure> {
        AnySubscriber(receiveSubscription: { [weak self] subscription in
            guard let self = self else { subscription.cancel(); return }
            self.lock.lock(); self.subscriptions[index] = subscription; self.lock.unlock()
            subscription.request(.unlimited)
        }, receiveValue: { [weak self] value in
            self?.receive(value, at: index)
            return .none
        }, receiveCompletion: { [weak self] completion in
            self?.complete(completion, at: index)
        })
    }

    private func receive(_ value: Any, at index: Int) {
        lock.lock()
        latest[index] = value
        pending = true
        lock.unlock()
        deliver()
    }

    private func deliver() {
        lock.lock()
        guard let downstream = downstream, pending, demand > 0, !latest.contains(where: { $0 == nil }) else { lock.unlock(); return }
        pending = false
        demand -= 1
        let values = latest.map { $0! }
        lock.unlock()
        let more = downstream.receive(combine(values))
        lock.lock(); demand += more; lock.unlock()
    }

    private func complete(_ completion: Subscribers.Completion<Failure>, at index: Int) {
        lock.lock()
        guard let downstream = downstream else { lock.unlock(); return }
        switch completion {
        case .failure:
            self.downstream = nil
            let others = subscriptions
            lock.unlock()
            others.forEach { $0?.cancel() }
            downstream.receive(completion: completion)
        case .finished:
            finished[index] = true
            let done = !finished.contains(false) || latest[index] == nil
            if done { self.downstream = nil }
            lock.unlock()
            if done { downstream.receive(completion: .finished) }
        }
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock(); self.demand += demand; lock.unlock()
        deliver()
    }

    deinit { lock.deallocate() }

    func cancel() {
        lock.lock()
        downstream = nil
        let all = subscriptions
        subscriptions = []
        lock.unlock()
        all.forEach { $0?.cancel() }
    }
}

extension Publishers {
    public struct CombineLatest<A, B>: Publisher where A: Publisher, B: Publisher, A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public init(_ a: A, _ b: B) { self.a = a; self.b = b }
        public func receive<S>(subscriber: S) where S: Subscriber, B.Failure == S.Failure, S.Input == (A.Output, B.Output) {
            let inner = _CombineLatestInner<S, Failure>(downstream: subscriber, count: 2) { ($0[0] as! A.Output, $0[1] as! B.Output) }
            subscriber.receive(subscription: inner)
            a.subscribe(inner.subscriber(0, A.Output.self))
            b.subscribe(inner.subscriber(1, B.Output.self))
        }
    }

    public struct CombineLatest3<A, B, C>: Publisher where A: Publisher, B: Publisher, C: Publisher, A.Failure == B.Failure, B.Failure == C.Failure {
        public typealias Output = (A.Output, B.Output, C.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public init(_ a: A, _ b: B, _ c: C) { self.a = a; self.b = b; self.c = c }
        public func receive<S>(subscriber: S) where S: Subscriber, C.Failure == S.Failure, S.Input == (A.Output, B.Output, C.Output) {
            let inner = _CombineLatestInner<S, Failure>(downstream: subscriber, count: 3) {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output)
            }
            subscriber.receive(subscription: inner)
            a.subscribe(inner.subscriber(0, A.Output.self))
            b.subscribe(inner.subscriber(1, B.Output.self))
            c.subscribe(inner.subscriber(2, C.Output.self))
        }
    }

    public struct Merge3<A, B, C>: Publisher where A: Publisher, B: Publisher, C: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public init(_ a: A, _ b: B, _ c: C) { self.a = a; self.b = b; self.c = c }
        public func receive<S>(subscriber: S) where C.Failure == S.Failure, C.Output == S.Input, S: Subscriber {
            Publishers.MergeMany(a.eraseToAnyPublisher(), b.eraseToAnyPublisher(), c.eraseToAnyPublisher()).subscribe(subscriber)
        }
    }
}

extension Publisher {
    public func combineLatest<P>(_ other: P) -> Publishers.CombineLatest<Self, P> where P: Publisher, Self.Failure == P.Failure {
        Publishers.CombineLatest(self, other)
    }
    public func combineLatest<P, Q>(_ publisher1: P, _ publisher2: Q) -> Publishers.CombineLatest3<Self, P, Q> where P: Publisher, Q: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure {
        Publishers.CombineLatest3(self, publisher1, publisher2)
    }
    public func merge(with other: Self) -> Publishers.MergeMany<Self> {
        Publishers.MergeMany(self, other)
    }
}

extension Publishers.Merge {
    public func merge<P>(with other: P) -> Publishers.Merge3<A, B, P> where P: Publisher, B.Failure == P.Failure, B.Output == P.Output {
        Publishers.Merge3(a, b, other)
    }
}

// MARK: - Result.Publisher

extension Result {
    public var publisher: Result<Success, Failure>.Publisher { Publisher(self) }

    public struct Publisher: Combine.Publisher {
        public typealias Output = Success
        public let result: Result<Result<Success, Failure>.Publisher.Output, Failure>
        public init(_ result: Result<Result<Success, Failure>.Publisher.Output, Failure>) { self.result = result }
        public init(_ output: Result<Success, Failure>.Publisher.Output) { result = .success(output) }
        public init(_ failure: Failure) { result = .failure(failure) }
        public func receive<S>(subscriber: S) where Success == S.Input, Failure == S.Failure, S: Subscriber {
            switch result {
            case .success(let value): Just(value).setFailureType(to: Failure.self).subscribe(subscriber)
            case .failure(let error): Fail(error: error).subscribe(subscriber)
            }
        }
    }
}
