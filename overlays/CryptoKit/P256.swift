// P-256 public keys for key agreement, with the API of Apple's CryptoKit. The point is decoded and
// checked against the curve by the runtime's LibreSSL (p256.c); the key keeps its X9.63 form.
// Key generation, signing and the key agreement itself are not implemented.
import Foundation
@_implementationOnly import DarlingP256

public enum P256 {
    public enum KeyAgreement {
        public struct PublicKey {
            private let x963: Data

            private init(validating bytes: UnsafeRawBufferPointer) throws {
                var point = [UInt8](repeating: 0, count: 65)
                let result = point.withUnsafeMutableBufferPointer {
                    darling_p256_public_key_decode(bytes.baseAddress, bytes.count, $0.baseAddress)
                }
                guard result == 0 else { throw CryptoKitError.underlyingCoreCryptoError(error: -1) }
                x963 = Data(point)
            }

            /// The uncompressed X9.63 form: 0x04, X, Y.
            public init<Bytes: ContiguousBytes>(x963Representation: Bytes) throws {
                try self = x963Representation.withUnsafeBytes { bytes in
                    guard bytes.count == 65 else { throw CryptoKitError.incorrectParameterSize }
                    return try PublicKey(validating: bytes)
                }
            }

            /// X and Y without the X9.63 prefix.
            public init<Bytes: ContiguousBytes>(rawRepresentation: Bytes) throws {
                try self = rawRepresentation.withUnsafeBytes { bytes in
                    guard bytes.count == 64 else { throw CryptoKitError.incorrectParameterSize }
                    var point = [UInt8](repeating: 4, count: 1)
                    point.append(contentsOf: bytes)
                    return try point.withUnsafeBytes { try PublicKey(validating: $0) }
                }
            }

            /// The compressed X9.62 form: 0x02 or 0x03 (the parity of Y), X.
            public init<Bytes: ContiguousBytes>(compressedRepresentation: Bytes) throws {
                try self = compressedRepresentation.withUnsafeBytes { bytes in
                    guard bytes.count == 33 else { throw CryptoKitError.incorrectParameterSize }
                    return try PublicKey(validating: bytes)
                }
            }

            public var x963Representation: Data { x963 }
            public var rawRepresentation: Data { x963.dropFirst() }
            public var compressedRepresentation: Data {
                var result = Data([x963[x963.startIndex + 64] & 1 == 0 ? 2 : 3])
                result.append(x963[(x963.startIndex + 1)...(x963.startIndex + 32)])
                return result
            }
        }
    }
}
