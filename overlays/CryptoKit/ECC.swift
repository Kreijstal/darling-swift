import Foundation
@_implementationOnly import DarlingECC

// Backend for swift-crypto's P-256 API files: the OpenSSL* names they select when
// CRYPTO_IN_SWIFTPM_FORCE_BUILD_API is defined, implemented over ecc.c. Keys are plain
// values (the scalar in SecureBytes, the public point in x9.63 form); the C bridge
// builds and frees its LibreSSL objects inside each call.

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
protocol OpenSSLSupportedNISTCurve {
    static var coordinateByteCount: Int { get }
    static var curveID: Int32 { get }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
extension P256: OpenSSLSupportedNISTCurve {
    static var coordinateByteCount: Int { 32 }
    static var curveID: Int32 { Int32(DARLING_ECC_P256) }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
private func backendError() -> CryptoKitError {
    CryptoKitError.underlyingCoreCryptoError(error: -1)
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
private func pointLength<Curve: OpenSSLSupportedNISTCurve>(_: Curve.Type) -> Int {
    2 * Curve.coordinateByteCount + 1
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
private func importPublic<Curve: OpenSSLSupportedNISTCurve>(_: Curve.Type, encoding: Int32,
    _ input: UnsafeRawBufferPointer) throws -> Data {
    var output = Data(count: pointLength(Curve.self))
    let rc = output.withUnsafeMutableBytes { out in
        darling_ecc_public_import(Curve.curveID, encoding,
            input.bindMemory(to: UInt8.self).baseAddress, input.count,
            out.bindMemory(to: UInt8.self).baseAddress, out.count)
    }
    guard rc == DARLING_ECC_OK else { throw backendError() }
    return output
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
struct OpenSSLNISTCurvePublicKeyImpl<Curve: OpenSSLSupportedNISTCurve> {
    /// 0x04 || X || Y, always a validated point on the curve.
    let x963: Data

    init(validatedX963 x963: Data) {
        self.x963 = x963
    }

    init<Bytes: ContiguousBytes>(rawRepresentation bytes: Bytes) throws {
        self.x963 = try bytes.withUnsafeBytes { input in
            guard input.count == 2 * Curve.coordinateByteCount else {
                throw CryptoKitError.incorrectParameterSize
            }
            return try importPublic(Curve.self, encoding: Int32(DARLING_ECC_RAW), input)
        }
    }

    init<Bytes: ContiguousBytes>(compactRepresentation bytes: Bytes) throws {
        self.x963 = try bytes.withUnsafeBytes { input in
            guard input.count == Curve.coordinateByteCount else {
                throw CryptoKitError.incorrectParameterSize
            }
            return try importPublic(Curve.self, encoding: Int32(DARLING_ECC_COMPACT), input)
        }
    }

    init<Bytes: ContiguousBytes>(x963Representation bytes: Bytes) throws {
        self.x963 = try bytes.withUnsafeBytes { input in
            guard input.count == pointLength(Curve.self) else {
                throw CryptoKitError.incorrectParameterSize
            }
            guard input[0] == 0x04 else { throw CryptoKitError.incorrectKeySize }
            return try importPublic(Curve.self, encoding: Int32(DARLING_ECC_X963), input)
        }
    }

    init<Bytes: ContiguousBytes>(compressedRepresentation bytes: Bytes) throws {
        self.x963 = try bytes.withUnsafeBytes { input in
            guard input.count == Curve.coordinateByteCount + 1 else {
                throw CryptoKitError.incorrectParameterSize
            }
            guard input[0] == 0x02 || input[0] == 0x03 else {
                throw CryptoKitError.incorrectKeySize
            }
            return try importPublic(Curve.self, encoding: Int32(DARLING_ECC_COMPRESSED), input)
        }
    }

    var compactRepresentation: Data? {
        let compact = x963.withUnsafeBytes { point in
            darling_ecc_is_compact(Curve.curveID,
                point.bindMemory(to: UInt8.self).baseAddress, point.count)
        }
        guard compact == 1 else { return nil }
        return Data(x963.dropFirst().prefix(Curve.coordinateByteCount))
    }

    var rawRepresentation: Data {
        Data(x963.dropFirst())
    }

    var x963Representation: Data {
        x963
    }

    var compressedRepresentation: Data {
        let y = x963.dropFirst(1 + Curve.coordinateByteCount)
        var out = Data([0x02 | (y[y.endIndex - 1] & 1)])
        out.append(x963.dropFirst().prefix(Curve.coordinateByteCount))
        return out
    }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
struct OpenSSLNISTCurvePrivateKeyImpl<Curve: OpenSSLSupportedNISTCurve> {
    /// Big-endian d, exactly coordinateByteCount bytes.
    let scalar: SecureBytes
    let publicX963: Data

    init(compactRepresentable: Bool = true) {
        let length = Curve.coordinateByteCount
        var point = Data(count: pointLength(Curve.self))
        var rc: Int32 = 0
        self.scalar = SecureBytes(unsafeUninitializedCapacity: length) { buffer, count in
            rc = point.withUnsafeMutableBytes { out in
                darling_ecc_generate(Curve.curveID, compactRepresentable ? 1 : 0,
                    buffer.bindMemory(to: UInt8.self).baseAddress, length,
                    out.bindMemory(to: UInt8.self).baseAddress, out.count)
            }
            count = length
        }
        guard rc == DARLING_ECC_OK else {
            fatalError("Looped more than 100 times trying to generate a key")
        }
        self.publicX963 = point
    }

    /// Validates d (and, for x9.63 import, that the stored point is d*G) and caches Q.
    private init(scalar: SecureBytes, expected: UnsafeRawBufferPointer?) throws {
        var point = Data(count: pointLength(Curve.self))
        let rc = scalar.withUnsafeBytes { d in
            point.withUnsafeMutableBytes { out in
                darling_ecc_private_import(Curve.curveID,
                    d.bindMemory(to: UInt8.self).baseAddress, d.count,
                    expected?.bindMemory(to: UInt8.self).baseAddress, expected?.count ?? 0,
                    out.bindMemory(to: UInt8.self).baseAddress, out.count)
            }
        }
        guard rc == DARLING_ECC_OK else { throw backendError() }
        self.scalar = scalar
        self.publicX963 = point
    }

    init<Bytes: ContiguousBytes>(x963 bytes: Bytes) throws {
        let length = Curve.coordinateByteCount
        let pointCount = pointLength(Curve.self)
        self = try bytes.withUnsafeBytes { input in
            guard input.count == pointCount + length else {
                throw CryptoKitError.incorrectParameterSize
            }
            guard input[0] == 0x04 else { throw CryptoKitError.incorrectKeySize }
            let scalar = SecureBytes(unsafeUninitializedCapacity: length) { buffer, count in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: input[pointCount...]))
                count = length
            }
            return try Self(scalar: scalar,
                expected: UnsafeRawBufferPointer(rebasing: input[..<pointCount]))
        }
    }

    init<Bytes: ContiguousBytes>(data bytes: Bytes) throws {
        let length = Curve.coordinateByteCount
        self = try bytes.withUnsafeBytes { input in
            guard input.count == length else { throw CryptoKitError.incorrectParameterSize }
            let scalar = SecureBytes(unsafeUninitializedCapacity: length) { buffer, count in
                buffer.copyMemory(from: input)
                count = length
            }
            return try Self(scalar: scalar, expected: nil)
        }
    }

    func publicKey() -> OpenSSLNISTCurvePublicKeyImpl<Curve> {
        OpenSSLNISTCurvePublicKeyImpl(validatedX963: publicX963)
    }

    var rawRepresentation: Data {
        Data(scalar)
    }

    var x963Representation: Data {
        var out = publicX963
        out.append(contentsOf: scalar)
        return out
    }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
extension P256.Signing.PrivateKey {
    func openSSLSignature<D: Digest>(for digest: D) throws -> P256.Signing.ECDSASignature {
        var raw = Data(count: 2 * P256.coordinateByteCount)
        let rc = self.impl.scalar.withUnsafeBytes { d in
            digest.withUnsafeBytes { message in
                raw.withUnsafeMutableBytes { out in
                    darling_ecc_sign(P256.curveID, d.bindMemory(to: UInt8.self).baseAddress, d.count,
                        message.bindMemory(to: UInt8.self).baseAddress, message.count,
                        out.bindMemory(to: UInt8.self).baseAddress, out.count)
                }
            }
        }
        guard rc == DARLING_ECC_OK else { throw backendError() }
        return try P256.Signing.ECDSASignature(rawRepresentation: raw)
    }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
extension P256.Signing.PublicKey {
    func openSSLIsValidSignature<D: Digest>(_ signature: P256.Signing.ECDSASignature,
        for digest: D) -> Bool {
        let rc = self.impl.x963.withUnsafeBytes { point in
            digest.withUnsafeBytes { message in
                signature.rawRepresentation.withUnsafeBytes { sig in
                    darling_ecc_verify(P256.curveID,
                        point.bindMemory(to: UInt8.self).baseAddress, point.count,
                        message.bindMemory(to: UInt8.self).baseAddress, message.count,
                        sig.bindMemory(to: UInt8.self).baseAddress, sig.count)
                }
            }
        }
        return rc == 1
    }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, macCatalyst 13, visionOS 1.0, *)
extension P256.KeyAgreement.PrivateKey {
    func openSSLSharedSecretFromKeyAgreement(with publicKeyShare: P256.KeyAgreement.PublicKey)
        throws -> SharedSecret {
        let length = P256.coordinateByteCount
        var rc: Int32 = 0
        let secret = self.impl.scalar.withUnsafeBytes { d in
            publicKeyShare.impl.x963.withUnsafeBytes { peer in
                SecureBytes(unsafeUninitializedCapacity: length) { buffer, count in
                    rc = darling_ecc_ecdh(P256.curveID,
                        d.bindMemory(to: UInt8.self).baseAddress, d.count,
                        peer.bindMemory(to: UInt8.self).baseAddress, peer.count,
                        buffer.bindMemory(to: UInt8.self).baseAddress, length)
                    count = length
                }
            }
        }
        guard rc == DARLING_ECC_OK else { throw backendError() }
        return SharedSecret(ss: secret)
    }
}
