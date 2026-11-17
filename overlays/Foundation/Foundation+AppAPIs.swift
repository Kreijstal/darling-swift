// URLSession's async methods, written from the declarations in Apple's SDK interface. Darling's headers have no
// API notes for the URL session classes, so they keep their NS names here (ObjC protocols mangle
// by their Objective-C name either way). The rest of what this file used to carry (URLError.NetworkUnavailableReason,
// URLRequest.allowsConstrainedNetworkAccess, NSDictionary as a Sequence, NSArray literals, String and StringProtocol
// helpers) is in URLError.swift, URLRequest.swift, NSDictionary.swift, NSArray.swift and NSStringAPI.swift.

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
