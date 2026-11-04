@_implementationOnly import DarlingDigests

// SHA-384 and SHA-512 with the public shape of swift-crypto's
// HashFunctions_SHA2.swift (Apache-2.0), which the base pin leaves out.
// Insecure.SHA1 and Insecure.MD5 come from its Insecure_HashFunctions.swift.
// All four hash through the runtime's LibreSSL, in digests.c.

public struct SHA384: HashFunctionImplementationDetails, Sendable {
    public static let blockByteCount: Int = 128
    public static let byteCount: Int = 48
    public typealias Digest = SHA384Digest
    var impl: DigestImpl<SHA384>

    public init() {
        impl = DigestImpl()
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        impl.update(data: bufferPointer)
    }

    public func finalize() -> Self.Digest {
        return impl.finalize()
    }
}

public struct SHA512: HashFunctionImplementationDetails, Sendable {
    public static let blockByteCount: Int = 128
    public static let byteCount: Int = 64
    public typealias Digest = SHA512Digest
    var impl: DigestImpl<SHA512>

    public init() {
        impl = DigestImpl()
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        impl.update(data: bufferPointer)
    }

    public func finalize() -> Self.Digest {
        return impl.finalize()
    }
}

/// A LibreSSL hash context, held in raw bytes so DarlingDigestImpl can copy it by value.
struct LibreSSLDigestContext {
    var bytes = [UInt8](repeating: 0, count: darling_crypto_digest_context_size())
}

protocol LibreSSLBackedHashFunction: DarlingBackedHashFunction where Context == LibreSSLDigestContext {
    /// The algorithm's number in digests.c.
    static var algorithm: Int32 { get }
}

extension LibreSSLBackedHashFunction {
    static var digestSize: Int { Self.Digest.byteCount }

    static func initialize() -> LibreSSLDigestContext {
        var context = LibreSSLDigestContext()
        context.bytes.withUnsafeMutableBytes { darling_crypto_digest_init(algorithm, $0.baseAddress) }
        return context
    }

    static func update(_ context: inout LibreSSLDigestContext, data: UnsafeRawBufferPointer) {
        context.bytes.withUnsafeMutableBytes {
            darling_crypto_digest_update(algorithm, $0.baseAddress, data.baseAddress, data.count)
        }
    }

    static func finalize(_ context: inout LibreSSLDigestContext, digest: UnsafeMutableRawBufferPointer) {
        precondition(digest.count == Self.digestSize)
        context.bytes.withUnsafeMutableBytes {
            darling_crypto_digest_final(algorithm, $0.baseAddress, digest.baseAddress)
        }
    }
}

extension SHA384: LibreSSLBackedHashFunction { static var algorithm: Int32 { 0 } }
extension SHA512: LibreSSLBackedHashFunction { static var algorithm: Int32 { 1 } }
extension Insecure.SHA1: LibreSSLBackedHashFunction { static var algorithm: Int32 { 2 } }
extension Insecure.MD5: LibreSSLBackedHashFunction { static var algorithm: Int32 { 3 } }
