// Parts of Apple's Combine that OpenCombine declares under other names, with the declarations of the iOS SDK's
// Combine interface so apps built against it link: Result.Publisher. (CombineLatest, Merge and the other publishers
// OpenCombine lacks are in ../Sources, and DispatchQueue's Scheduler conformance is in the Dispatch overlay, where
// current SDKs declare it.)

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
