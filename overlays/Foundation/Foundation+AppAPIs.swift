// Smaller pieces of Apple's Foundation overlay that iOS apps import, written from the declarations
// in Apple's SDK interface: URLSession's async methods, URLError.NetworkUnavailableReason,
// NSDictionary and NSArray as Swift collections, and a few String helpers. Darling's headers have no
// API notes for the URL session classes, so they keep their NS names here (ObjC protocols mangle
// by their Objective-C name either way).

// MARK: - URLSession async

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension URLSession {
    private func _response(_ make: (@escaping (Data?, URLResponse?, Error?) -> Void) -> NSURLSessionTask) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            make { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let response = response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    public func data(for request: URLRequest, delegate: (any NSURLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await _response { dataTask(with: request, completionHandler: $0) }
    }

    public func data(from url: URL, delegate: (any NSURLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await _response { dataTask(with: url, completionHandler: $0) }
    }

    public func upload(for request: URLRequest, from bodyData: Data, delegate: (any NSURLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await _response { uploadTask(with: request, from: bodyData, completionHandler: $0) }
    }
}

// MARK: - URLError

extension URLError {
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public enum NetworkUnavailableReason: Int, Sendable {
        case cellular = 0
        case expensive = 1
        case constrained = 2
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public var networkUnavailableReason: URLError.NetworkUnavailableReason? {
        guard let reason = _nsError.userInfo()?["NSURLErrorNetworkUnavailableReasonKey"] as? NSNumber else { return nil }
        return NetworkUnavailableReason(rawValue: Int(reason.int32Value))
    }
}

// MARK: - URLRequest

extension URLRequest {
    /// Darling's NSURLRequest has no constrained-network ("Low Data Mode") flag: always allowed.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public var allowsConstrainedNetworkAccess: Bool {
        get { true }
        set {}
    }
}

// MARK: - NSDictionary and NSArray

extension NSDictionary: Sequence {
    @_objcRuntimeName(_TtCE10FoundationCSo12NSDictionary9_Iterator)
    final public class Iterator: IteratorProtocol {
        private let dictionary: NSDictionary
        private let keys: NSEnumerator

        fileprivate init(_ dictionary: NSDictionary) {
            self.dictionary = dictionary
            keys = dictionary.keyEnumerator()
        }

        final public func next() -> (key: Any, value: Any)? {
            guard let key = keys.nextObject(), let value = dictionary.object(forKey: key) else { return nil }
            return (key: key, value: value)
        }

        public typealias Element = (key: Any, value: Any)
    }

    public func makeIterator() -> NSDictionary.Iterator { Iterator(self) }
}

extension NSArray: ExpressibleByArrayLiteral {
    required public convenience init(arrayLiteral elements: Any...) {
        self.init(array: elements)
    }
}

// MARK: - String

extension String {
    public init?<S>(bytes: __shared S, encoding: String.Encoding) where S: Sequence, S.Element == UInt8 {
        let bytes = Array(bytes)
        guard let string = bytes.withUnsafeBufferPointer({ buffer in
            NSString(bytes: UnsafeRawPointer(buffer.baseAddress) ?? UnsafeRawPointer(bitPattern: 1)!, length: buffer.count, encoding: encoding.rawValue)
        }) else { return nil }
        self = string as String
    }
}

extension StringProtocol {
    public func folding(options: String.CompareOptions = [], locale: Locale?) -> String {
        NSString(string: String(self)).folding(options: options, locale: locale)
    }
}
