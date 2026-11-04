import Foundation
import CryptoKit

// P-256, SharedSecret and HKDF checks. Constants: SEC 2 v2.0 section 2.4.2 / FIPS 186-4
// D.1.2.3. Vector sources are named at each section; the large sets come from
// vectors.swift, which tests/vectors.py generates from the pinned swift-crypto checkout.

private let fieldPrime = "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
private let groupOrder = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
private let gx = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
private let gy = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"

private func field(_ text: Substring) -> Data {
    text == "-" ? Data() : hex(String(text))
}

private func lines(_ table: String) -> [[Substring]] {
    table.split(separator: "\n").map { $0.split(separator: " ") }
}

private func bytes<B: ContiguousBytes>(_ value: B) -> Data {
    value.withUnsafeBytes { Data($0) }
}

private func expect(_ expected: CryptoKitError, _ what: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch let error as CryptoKitError {
        switch (error, expected) {
        case (.underlyingCoreCryptoError, .underlyingCoreCryptoError):
            return
        default:
            precondition(error == expected, "\(what): threw \(error), expected \(expected)")
            return
        }
    } catch {
        preconditionFailure("\(what): threw \(error), expected \(expected)")
    }
    preconditionFailure("\(what): accepted, expected \(expected)")
}

private func expectASN1(_ expected: CryptoKitASN1Error, _ what: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch let error as CryptoKitASN1Error {
        precondition(error == expected, "\(what): threw \(error), expected \(expected)")
        return
    } catch {
        preconditionFailure("\(what): threw \(error), expected \(expected)")
    }
    preconditionFailure("\(what): accepted, expected \(expected)")
}

private func throwsAnything(_ what: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        return
    }
    preconditionFailure("\(what): accepted")
}

/// ANSI X9.63 KDF over SHA-256 (SEC 1 v2.0 section 3.6.1), written independently of the API.
private func referenceX963(_ z: Data, _ sharedInfo: Data, _ count: Int) -> Data {
    var out = Data()
    var counter: UInt32 = 1
    while out.count < count {
        var hasher = SHA256()
        hasher.update(data: z)
        hasher.update(data: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        hasher.update(data: sharedInfo)
        out.append(contentsOf: hasher.finalize())
        counter += 1
    }
    return out.prefix(count)
}

/// precondition() whose condition may throw; failures name the source line.
private func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    line: UInt = #line) throws {
    let ok = try condition()
    precondition(ok, "p256.swift:\(line) \(message())")
}

private func keysAndEncodings() throws {
    // A.1: d = 1 gives G.
    let one = hex(String(repeating: "0", count: 62) + "01")
    let g = try P256.Signing.PrivateKey(rawRepresentation: one).publicKey
    try check(g.x963Representation == hex("04" + gx + gy))
    try check(g.rawRepresentation == hex(gx + gy))
    try check(g.compressedRepresentation == hex("03" + gx))
    try check(g.compactRepresentation == hex(gx))

    // A.2: d = n - 1 gives -G = (Gx, p - Gy).
    let pMinusGy = "b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a"
    let nMinusOne = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550"
    let minusG = try P256.Signing.PrivateKey(rawRepresentation: hex(nMinusOne)).publicKey
    try check(minusG.x963Representation == hex("04" + gx + pMinusGy))
    try check(minusG.compressedRepresentation == hex("02" + gx))
    try check(minusG.compactRepresentation == nil)

    // A.3: the scalar must lie in [1, n - 1].
    expect(.underlyingCoreCryptoError(error: -1), "d = 0") {
        _ = try P256.Signing.PrivateKey(rawRepresentation: Data(count: 32))
    }
    expect(.underlyingCoreCryptoError(error: -1), "d = n") {
        _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(groupOrder))
    }
    expect(.underlyingCoreCryptoError(error: -1), "d = 2^256 - 1") {
        _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xff, count: 32))
    }

    // A.4: RFC 6979 A.2.5 key pair.
    let rfc6979 = try P256.Signing.PrivateKey(rawRepresentation:
        hex("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"))
    try check(rfc6979.publicKey.rawRepresentation == hex(
        "60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6" +
        "7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299"))

    // A.5: RFC 4754 section 8.1 key pair.
    let rfc4754 = try P256.Signing.PrivateKey(rawRepresentation:
        hex("dc51d3866a15bacde33d96f992fca99da7e6ef0934e7097559c27f1614c88a7f"))
    try check(rfc4754.publicKey.rawRepresentation == hex(
        "2442a5cc0ecd015fa3ca31dc8e2bbc70bf42d60cbca20085e0822cb04235e970" +
        "6fc98bd7e50211a4a27102fa3549df79ebcb4bf246b80945cddfe7d509bbfd7d"))

    // Private x9.63 round trip and layout: 04 || X || Y || d.
    try check(rfc4754.x963Representation == rfc4754.publicKey.x963Representation +
        rfc4754.rawRepresentation)
    let reimported = try P256.Signing.PrivateKey(x963Representation: rfc4754.x963Representation)
    try check(reimported.rawRepresentation == rfc4754.rawRepresentation)

    // A.6: round trips with random keys.
    for _ in 0..<8 {
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        for (raw, x963, pub) in [
            (signing.rawRepresentation, signing.x963Representation, signing.publicKey.x963Representation),
            (agreement.rawRepresentation, agreement.x963Representation, agreement.publicKey.x963Representation),
        ] {
            try check(try P256.Signing.PrivateKey(rawRepresentation: raw).rawRepresentation == raw)
            try check(try P256.KeyAgreement.PrivateKey(x963Representation: x963).x963Representation == x963)
            let key = try P256.Signing.PublicKey(x963Representation: pub)
            try check(try P256.Signing.PublicKey(rawRepresentation: key.rawRepresentation)
                .x963Representation == pub)
            try check(try P256.KeyAgreement.PublicKey(compressedRepresentation:
                key.compressedRepresentation).x963Representation == pub)
            let compact = try P256.Signing.PublicKey(compactRepresentation: key.compactRepresentation!)
            try check(compact.x963Representation == pub)
            try check(P256.Signing.PrivateKey(compactRepresentable: true).publicKey
                .compactRepresentation != nil)
        }
    }
    var nonCompact: P256.KeyAgreement.PrivateKey? = nil
    for _ in 0..<10_000 {
        let candidate = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
        if candidate.publicKey.compactRepresentation == nil {
            nonCompact = candidate
            break
        }
    }
    let other = nonCompact!
    expect(.incorrectParameterSize, "compact init with 64 bytes") {
        _ = try P256.KeyAgreement.PublicKey(compactRepresentation: other.publicKey.rawRepresentation)
    }
    let compactKey = P256.KeyAgreement.PrivateKey(compactRepresentable: true)
    let ab = try compactKey.sharedSecretFromKeyAgreement(with: other.publicKey)
    let ba = try other.sharedSecretFromKeyAgreement(with: compactKey.publicKey)
    try check(ab == ba && bytes(ab) == bytes(ba))

    // A.7: swift-crypto testCompressedKeys / testUncompressedKeys (P-256 parts).
    let positive = Data(base64Encoded: "A+QHCXtGd5WWSQgp37FBPXMy+nnSwFK79QQD0ZeNMv7L")!
    try check(try P256.Signing.PublicKey(compressedRepresentation: positive)
        .x963Representation.base64EncodedString() ==
        "BOQHCXtGd5WWSQgp37FBPXMy+nnSwFK79QQD0ZeNMv7LE6xvfFkB4Y3VXoOpB/Kp6ngpf3Lce9hDMl7fqaDUfYE=")
    let negative = Data(base64Encoded: "AuQHCXtGd5WWSQgp37FBPXMy+nnSwFK79QQD0ZeNMv7L")!
    try check(try P256.Signing.PublicKey(compressedRepresentation: negative)
        .x963Representation.base64EncodedString() ==
        "BOQHCXtGd5WWSQgp37FBPXMy+nnSwFK79QQD0ZeNMv7L7FOQgqb+HnMqoXxW+A1WFYfWgI4jhCe8zaEgVl8rgn4=")
    let uncompressed = Data(base64Encoded:
        "BOQHCXtGd5WWSQgp37FBPXMy+nnSwFK79QQD0ZeNMv7LE6xvfFkB4Y3VXoOpB/Kp6ngpf3Lce9hDMl7fqaDUfYE=")!
    throwsAnything("65 bytes to compressed init") {
        _ = try P256.Signing.PublicKey(compressedRepresentation: uncompressed)
    }
    try check(try P256.Signing.PublicKey(x963Representation: uncompressed)
        .x963Representation == uncompressed)
    expect(.incorrectParameterSize, "33 bytes to x963 init") {
        _ = try P256.KeyAgreement.PublicKey(x963Representation: positive)
    }

    // A.8: X with no square root (1 - 3 + b is a non-residue mod p), and X = p.
    let xOne = hex(String(repeating: "0", count: 62) + "01")
    expect(.underlyingCoreCryptoError(error: -1), "compact X = 1") {
        _ = try P256.Signing.PublicKey(compactRepresentation: xOne)
    }
    expect(.underlyingCoreCryptoError(error: -1), "compressed X = 1") {
        _ = try P256.Signing.PublicKey(compressedRepresentation: hex("02") + xOne)
    }
    expect(.underlyingCoreCryptoError(error: -1), "compact X = p") {
        _ = try P256.Signing.PublicKey(compactRepresentation: hex(fieldPrime))
    }
    expect(.underlyingCoreCryptoError(error: -1), "compressed X = p") {
        _ = try P256.Signing.PublicKey(compressedRepresentation: hex("03" + fieldPrime))
    }

    // A.9: exact errors.
    expect(.incorrectParameterSize, "31-byte scalar") {
        _ = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 31))
    }
    expect(.incorrectParameterSize, "33-byte scalar") {
        _ = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 33))
    }
    var badPrivate = rfc4754.x963Representation
    badPrivate[badPrivate.startIndex] = 0x05
    expect(.incorrectKeySize, "private x963 with 0x05") {
        _ = try P256.Signing.PrivateKey(x963Representation: badPrivate)
    }
    var badPublic = rfc4754.publicKey.x963Representation
    badPublic[badPublic.startIndex] = 0x05
    expect(.incorrectKeySize, "public x963 with 0x05") {
        _ = try P256.Signing.PublicKey(x963Representation: badPublic)
    }
    expect(.incorrectKeySize, "compressed with 0x04") {
        _ = try P256.Signing.PublicKey(compressedRepresentation: hex("04") + hex(gx))
    }
    expect(.incorrectParameterSize, "ECDSASignature(rawRepresentation: hello)") {
        _ = try P256.Signing.ECDSASignature(rawRepresentation: Data("hello".utf8))
    }
    var offCurve = rfc4754.publicKey.x963Representation
    offCurve[offCurve.endIndex - 1] &+= 1
    expect(.underlyingCoreCryptoError(error: -1), "public point with Y + 1") {
        _ = try P256.Signing.PublicKey(x963Representation: offCurve)
    }
    expect(.underlyingCoreCryptoError(error: -1), "private x963 whose Q belongs to another d") {
        _ = try P256.Signing.PrivateKey(x963Representation:
            rfc6979.publicKey.x963Representation + rfc4754.rawRepresentation)
    }
    expect(.underlyingCoreCryptoError(error: -1), "public point at infinity") {
        _ = try P256.Signing.PublicKey(rawRepresentation: Data(count: 64))
    }

    // A.10: PEM and DER fixtures from swift-crypto ECKeyEncodingsTests.
    let spkiPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEb4nB0k8CBVnKCHVHkxuXAkSlZuO5
    Nsev1rzcRv5QHiJuWUKomFGadQlMSGwoDOHEDdW3ujcA6t0ADteHw6KrZg==
    -----END PUBLIC KEY-----
    """
    let spkiSigning = try P256.Signing.PublicKey(pemRepresentation: spkiPEM)
    let spkiAgreement = try P256.KeyAgreement.PublicKey(pemRepresentation: spkiPEM)
    try check(spkiSigning.rawRepresentation == spkiAgreement.rawRepresentation)
    try check(spkiSigning.pemRepresentation == spkiPEM)
    try check(spkiAgreement.pemRepresentation == spkiPEM)
    expectASN1(.invalidPEMDocument, "SPKI PEM to Signing.PrivateKey") {
        _ = try P256.Signing.PrivateKey(pemRepresentation: spkiPEM)
    }
    expectASN1(.invalidPEMDocument, "SPKI PEM to KeyAgreement.PrivateKey") {
        _ = try P256.KeyAgreement.PrivateKey(pemRepresentation: spkiPEM)
    }

    let pkcs8PEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZjQLlzempZx7YF1F
    +MK1HWZTNgLcC1MAufb/2/YZYk6hRANCAAQwgn0PfkIHiZ/K+3zA//CoDqU2PqDc
    aA3U5R68jmlZQITvMyBlMJl9Mjh0biIe88dAfRKeUm9FVMD2ErJ/006V
    -----END PRIVATE KEY-----
    """
    let pkcs8Signing = try P256.Signing.PrivateKey(pemRepresentation: pkcs8PEM)
    let pkcs8Agreement = try P256.KeyAgreement.PrivateKey(pemRepresentation: pkcs8PEM)
    try check(pkcs8Signing.rawRepresentation == pkcs8Agreement.rawRepresentation)
    try check(pkcs8Signing.pemRepresentation == pkcs8PEM)
    try check(pkcs8Agreement.pemRepresentation == pkcs8PEM)
    expectASN1(.invalidPEMDocument, "PKCS#8 PEM to Signing.PublicKey") {
        _ = try P256.Signing.PublicKey(pemRepresentation: pkcs8PEM)
    }
    expectASN1(.invalidPEMDocument, "PKCS#8 PEM to KeyAgreement.PublicKey") {
        _ = try P256.KeyAgreement.PublicKey(pemRepresentation: pkcs8PEM)
    }

    let sec1PEM = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIHwS3r7tdBfDPSOaT/x6A2qvXFFXlGmnaYkxzrj1CQUHoAoGCCqGSM49
    AwEHoUQDQgAE79HvsMQC9IyhZ7yCCYKmgz9zewM4KziWoVMXKN+7Cd5Ds+jK8V5q
    hD6YVbbo/v1udmM5DfhHJiUW3Ww5++suRg==
    -----END EC PRIVATE KEY-----
    """
    try check(try P256.Signing.PrivateKey(pemRepresentation: sec1PEM).rawRepresentation ==
        P256.KeyAgreement.PrivateKey(pemRepresentation: sec1PEM).rawRepresentation)

    let spkiDER = Data(base64Encoded: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIq+Qd2HviOb1JAkvKInCCec/gbZRnEZ6H9gO29wJ1H/a8Mmmog7b8nj+xEgo7Rh5dKlNgRaKvVjlLDllq+bPAA==")!
    let derSigning = try P256.Signing.PublicKey(derRepresentation: spkiDER)
    try check(derSigning.rawRepresentation ==
        (try P256.KeyAgreement.PublicKey(derRepresentation: spkiDER)).rawRepresentation)
    try check(derSigning.derRepresentation == spkiDER)
    let pkcs8DER = Data(base64Encoded: "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgxWaWfbbhHsTjtEwkANo6ZDeJ2CARYhjOSt2auAW7xNOhRANCAAQsAL3hTMCCbh1kVCSJa8V22WLNDriEpVOLEJXiVFEwAFjWd1BufewuT69tYa0hyB1Q3pt12HPK2c1KGwjOpScW")!
    let derPrivate = try P256.Signing.PrivateKey(derRepresentation: pkcs8DER)
    try check(derPrivate.rawRepresentation ==
        (try P256.KeyAgreement.PrivateKey(derRepresentation: pkcs8DER)).rawRepresentation)
    try check(derPrivate.derRepresentation == pkcs8DER)
    let sec1DER = Data(base64Encoded: "MHcCAQEEIKzmkxtADyr8LymuVMqpLFVlx27bdgT0+un4I2a3DE1KoAoGCCqGSM49AwEHoUQDQgAEZp2q8QP4shIBZIHS1b1ZBUeLbrpnTA6CB17iFzF8udyYmcRkDAPSBamFXf4IthinYkfnru/PymZl+tpeM56BOw==")!
    try check(try P256.Signing.PrivateKey(derRepresentation: sec1DER).rawRepresentation ==
        P256.KeyAgreement.PrivateKey(derRepresentation: sec1DER).rawRepresentation)

    // E: Foundation base64 round trip of the PEM bodies.
    for pem in [spkiPEM, pkcs8PEM, sec1PEM] {
        let body = pem.split(separator: "\n").dropFirst().dropLast().joined()
        let decoded = Data(base64Encoded: body)!
        try check(decoded.base64EncodedString() == body)
    }
    print("P-256 keys: generator, scalar range, RFC 6979/4754 key pairs, x9.63/raw/compressed/compact, PEM/DER and errors pass")
}

private func ecdsa() throws {
    // B.1/B.2: RFC 6979 A.2.5 SHA-256 signatures (verification only: LibreSSL signs with a random k).
    let key = try P256.Signing.PrivateKey(rawRepresentation:
        hex("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")).publicKey
    let cases = [
        ("sample", "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716",
            "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8", "3046022100", "022100"),
        ("test", "f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367",
            "019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083", "3045022100", "0220"),
    ]
    for (index, (message, r, s, derHead, derMiddle)) in cases.enumerated() {
        let data = Data(message.utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: hex(r + s))
        try check(key.isValidSignature(signature, for: data))
        try check(key.isValidSignature(signature, for: SHA256.hash(data: data)))
        try check(!key.isValidSignature(signature, for: Data(cases[1 - index].0.utf8)))
        for bit in [0, 255, 256, 511] {
            var raw = signature.rawRepresentation
            raw[raw.startIndex + bit / 8] ^= UInt8(1 << (bit % 8))
            try check(!key.isValidSignature(try .init(rawRepresentation: raw), for: data))
        }
        var tampered = data
        tampered[tampered.startIndex] ^= 1
        try check(!key.isValidSignature(signature, for: tampered))
        let der = hex(derHead + r + derMiddle + s)
        try check(signature.derRepresentation == der)
        try check(try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation ==
            signature.rawRepresentation)
    }

    // B.3: RFC 4754 section 8.1, message "abc".
    let rfc4754 = try P256.Signing.PublicKey(rawRepresentation: hex(
        "2442a5cc0ecd015fa3ca31dc8e2bbc70bf42d60cbca20085e0822cb04235e970" +
        "6fc98bd7e50211a4a27102fa3549df79ebcb4bf246b80945cddfe7d509bbfd7d"))
    try check(rfc4754.isValidSignature(try .init(rawRepresentation: hex(
        "cb28e0999b9c7715fd0a80d8e47a77079716cbbf917dd72e97566ea1c066957c" +
        "86fa3bb4e26cad5bf90b7f81899256ce7594bb1ea0c89212748bff3b3d5b0315")), for: Data("abc".utf8)))

    // B.4: sign and verify with random keys.
    let signer = P256.Signing.PrivateKey()
    let message = Data("Darling P-256".utf8)
    let first = try signer.signature(for: message)
    let second = try signer.signature(for: message)
    try check(first.rawRepresentation != second.rawRepresentation)
    try check(signer.publicKey.isValidSignature(first, for: message))
    try check(signer.publicKey.isValidSignature(second, for: SHA256.hash(data: message)))
    let digestSignature = try signer.signature(for: SHA256.hash(data: message))
    try check(signer.publicKey.isValidSignature(digestSignature, for: message))
    try check(!P256.Signing.PrivateKey().publicKey.isValidSignature(first, for: message))
    try check(!signer.publicKey.isValidSignature(
        try .init(rawRepresentation: Data(count: 64)), for: message))
    try check(!signer.publicKey.isValidSignature(
        try .init(rawRepresentation: hex(groupOrder + groupOrder)), for: message))

    // B.5: Wycheproof, with swift-crypto's ECDSASignatureTests acceptance rule.
    var checked = 0
    for (table, der) in [(wycheproofECDSADER, true), (wycheproofECDSAP1363, false)] {
        for row in lines(table) {
            let msg = field(row[2])
            if msg.isEmpty { continue }
            let publicKey = try P256.Signing.PublicKey(x963Representation: field(row[1]))
            let result = row[4]
            let signature: P256.Signing.ECDSASignature
            do {
                signature = der ? try .init(derRepresentation: field(row[3]))
                    : try .init(rawRepresentation: field(row[3]))
            } catch {
                try check(result == "invalid" || result == "acceptable", "ECDSA tcId \(row[0])")
                checked += 1
                continue
            }
            let valid = publicKey.isValidSignature(signature, for: SHA256.hash(data: msg))
            try check(valid == (result != "invalid"),
                "ECDSA \(der ? "DER" : "P1363") tcId \(row[0]): \(result), got \(valid)")
            checked += 1
        }
    }
    print("P-256 ECDSA: RFC 6979 A.2.5, RFC 4754, DER encoding, randomized signing and \(checked) Wycheproof vectors pass")
}

private func paddedScalar(_ text: Substring) -> Data {
    let even = text.count % 2 == 0 ? String(text) : "0" + text
    let value = hex(even)
    if value.count >= 32 { return Data(value.suffix(32)) }
    return Data(count: 32 - value.count) + value
}

private func ecdh() throws {
    // C.1: NIST CAVP KAS ECC CDH primitive, P-256.
    for row in lines(cavpECCCDHP256) {
        let mine = try P256.KeyAgreement.PrivateKey(rawRepresentation: field(row[2]))
        try check(mine.publicKey.rawRepresentation == field(row[3]) + field(row[4]))
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: field(row[0]) + field(row[1]))
        let secret = try mine.sharedSecretFromKeyAgreement(with: peer)
        try check(bytes(secret) == field(row[5]))
    }

    // C.2: Wycheproof ecpoint, with swift-crypto's secpECDH_Runner acceptance rule.
    var points = 0
    for row in lines(wycheproofECDHPoint) {
        let result = row[5]
        do {
            let publicKey = row[1] == "compressed"
                ? try P256.KeyAgreement.PublicKey(compressedRepresentation: field(row[2]))
                : try P256.KeyAgreement.PublicKey(x963Representation: field(row[2]))
            let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: paddedScalar(row[3]))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            try check(bytes(secret) == field(row[4]), "ECDH ecpoint tcId \(row[0]) secret")
            try check(result == "valid" || result == "acceptable", "ECDH ecpoint tcId \(row[0]) accepted")
        } catch {
            try check(result == "invalid", "ECDH ecpoint tcId \(row[0]) rejected: \(error)")
        }
        points += 1
    }

    // C.3: Wycheproof SPKI through the public DER init; only valid vectors are asserted.
    var spki = 0
    for row in lines(wycheproofECDHSPKI) where row[5] == "valid" {
        let publicKey = try P256.KeyAgreement.PublicKey(derRepresentation: field(row[2]))
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: paddedScalar(row[3]))
        try check(bytes(try privateKey.sharedSecretFromKeyAgreement(with: publicKey)) == field(row[4]),
            "ECDH SPKI tcId \(row[0])")
        spki += 1
    }
    print("P-256 ECDH: 25 CAVP CDH vectors, \(points) Wycheproof ecpoint and \(spki) valid Wycheproof SPKI vectors pass")
}

private func kdfs() throws {
    // D.1: RFC 5869 A.1-A.3.
    for row in lines(rfc5869SHA256) {
        let ikm = SymmetricKey(data: field(row[0]))
        let salt = field(row[1]), info = field(row[2])
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        try check(Data(prk) == field(row[4]))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info,
            outputByteCount: Int(row[3])!)
        try check(bytes(okm) == field(row[5]))
    }

    // D.2a: the reference x9.63 KDF against CAVS 12.0 [SHA-256].
    var cavs = 0
    for row in lines(cavsX963SHA256) {
        let expected = field(row[2])
        try check(referenceX963(field(row[0]), field(row[1]), expected.count) == expected)
        cavs += 1
    }

    // D.2b/D.3: SharedSecret from CAVP COUNT 0.
    let count0 = lines(cavpECCCDHP256)[0]
    let z = field(count0[5])
    let secret = try P256.KeyAgreement.PrivateKey(rawRepresentation: field(count0[2]))
        .sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(
            rawRepresentation: field(count0[0]) + field(count0[1])))
    for info in [Data(), Data("abc".utf8)] {
        for length in [0, 16, 32, 33, 64] {
            try check(bytes(secret.x963DerivedSymmetricKey(using: SHA256.self, sharedInfo: info,
                outputByteCount: length)) == referenceX963(z, info, length))
        }
        let salt = Data("salt".utf8)
        try check(bytes(secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: info, outputByteCount: 42)) == bytes(HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: z), salt: salt, info: info, outputByteCount: 42)))
    }
    try check(secret == z)
    var flipped = z
    flipped[flipped.startIndex] ^= 1
    try check(!(secret == flipped))
    try check(secret.description.hasPrefix("SharedSecret: "))
    print("SharedSecret and HKDF: RFC 5869, \(cavs) CAVS x9.63 SHA-256 vectors, KDF agreement and equality pass")
}

func runP256Tests() {
    do {
        try keysAndEncodings()
        try ecdsa()
        try ecdh()
        try kdfs()
    } catch {
        preconditionFailure("unexpected error: \(error)")
    }
}

// NIST CAVP KAS ECC CDH Primitive, KAS_ECC_CDH_PrimitiveTest.txt (ecccdhtestvectors.zip,
// CAVS 14.1, generated 2012-11-19), section [P-256], COUNT 0-24:
// QCAVSx QCAVSy dIUT QIUTx QIUTy ZIUT.
let cavpECCCDHP256 = """
700c48f77f56584c5cc632ca65640db91b6bacce3a4df6b42ce7cc838833d287 db71e509e3fd9b060ddb20ba5c51dcc5948d46fbf640dfe0441782cab85fa4ac 7d7dc5f71eb29ddaf80d6214632eeae03d9058af1fb6d22ed80badb62bc1a534 ead218590119e8876b29146ff89ca61770c4edbbf97d38ce385ed281d8a6b230 28af61281fd35e2fa7002523acc85a429cb06ee6648325389f59edfce1405141 46fc62106420ff012e54a434fbdd2d25ccc5852060561e68040dd7778997bd7b
809f04289c64348c01515eb03d5ce7ac1a8cb9498f5caa50197e58d43a86a7ae b29d84e811197f25eba8f5194092cb6ff440e26d4421011372461f579271cda3 38f65d6dce47676044d58ce5139582d568f64bb16098d179dbab07741dd5caf5 119f2f047902782ab0c9e27a54aff5eb9b964829ca99c06b02ddba95b0a3f6d0 8f52b726664cac366fc98ac7a012b2682cbd962e5acb544671d41b9445704d1d 057d636096cb80b67a8c038c890e887d1adfa4195e9b3ce241c8a778c59cda67
a2339c12d4a03c33546de533268b4ad667debf458b464d77443636440ee7fec3 ef48a3ab26e20220bcda2c1851076839dae88eae962869a497bf73cb66faf536 1accfaf1b97712b85a6f54b148985a1bdc4c9bec0bd258cad4b3d603f49f32c8 d9f2b79c172845bfdb560bbb01447ca5ecc0470a09513b6126902c6b4f8d1051 f815ef5ec32128d3487834764678702e64e164ff7315185e23aff5facd96d7bc 2d457b78b4614132477618a5b077965ec90730a8c81a1c75d6d4ec68005d67ec
df3989b9fa55495719b3cf46dccd28b5153f7808191dd518eff0c3cff2b705ed 422294ff46003429d739a33206c8752552c8ba54a270defc06e221e0feaf6ac4 207c43a79bfee03db6f4b944f53d2fb76cc49ef1c9c4d34d51b6c65c4db6932d 24277c33f450462dcb3d4801d57b9ced05188f16c28eda873258048cd1607e0d c4789753e2b1f63b32ff014ec42cd6a69fac81dfe6d0d6fd4af372ae27c46f88 96441259534b80f6aee3d287a6bb17b5094dd4277d9e294f8fe73e48bf2a0024
41192d2813e79561e6a1d6f53c8bc1a433a199c835e141b05a74a97b0faeb922 1af98cc45e98a7e041b01cf35f462b7562281351c8ebf3ffa02e33a0722a1328 59137e38152350b195c9718d39673d519838055ad908dd4757152fd8255c09bf a8c5fdce8b62c5ada598f141adb3b26cf254c280b2857a63d2ad783a73115f6b 806e1aafec4af80a0d786b3de45375b517a7e5b51ffb2c356537c9e6ef227d4a 19d44c8d63e8e8dd12c22a87b8cd4ece27acdde04dbf47f7f27537a6999a8e62
33e82092a0f1fb38f5649d5867fba28b503172b7035574bf8e5b7100a3052792 f2cf6b601e0a05945e335550bf648d782f46186c772c0f20d3cd0d6b8ca14b2f f5f8e0174610a661277979b58ce5c90fee6c9b3bb346a90a7196255e40b132ef 7b861dcd2844a5a8363f6b8ef8d493640f55879217189d80326aad9480dfc149 c4675b45eeb306405f6c33c38bc69eb2bdec9b75ad5af4706aab84543b9cc63a 664e45d5bba4ac931cd65d52017e4be9b19a515f669bea4703542a2c525cd3d3
6a9e0c3f916e4e315c91147be571686d90464e8bf981d34a90b6353bca6eeba7 40f9bead39c2f2bcc2602f75b8a73ec7bdffcbcead159d0174c6c4d3c5357f05 3b589af7db03459c23068b64f63f28d3c3c6bc25b5bf76ac05f35482888b5190 9fb38e2d58ea1baf7622e96720101cae3cde4ba6c1e9fa26d9b1de0899102863 d5561b900406edf50802dd7d73e89395f8aed72fba0e1d1b61fe1d22302260f0 ca342daa50dc09d61be7c196c85e60a80c5cb04931746820be548cdde055679d
a9c0acade55c2a73ead1a86fb0a9713223c82475791cd0e210b046412ce224bb f6de0afa20e93e078467c053d241903edad734c6b403ba758c2b5ff04c9d4229 d8bf929a20ea7436b2461b541a11c80e61d826c0a4c9d322b31dd54e7f58b9c8 20f07631e4a6512a89ad487c4e9d63039e579cb0d7a556cb9e661cd59c1e7fa4 6de91846b3eee8a5ec09c2ab1f41e21bd83620ccdd1bdce3ab7ea6e02dd274f5 35aa9b52536a461bfde4e85fc756be928c7de97923f0416c7a3ac8f88b3d4489
94e94f16a98255fff2b9ac0c9598aac35487b3232d3231bd93b7db7df36f9eb9 d8049a43579cfa90b8093a94416cbefbf93386f15b3f6e190b6e3455fedfe69a 0f9883ba0ef32ee75ded0d8bda39a5146a29f1f2507b3bd458dbea0b2bb05b4d abb61b423be5d6c26e21c605832c9142dc1dfe5a5fff28726737936e6fbf516d 733d2513ef58beab202090586fac91bf0fee31e80ab33473ab23a2d89e58fad6 605c16178a9bc875dcbff54d63fe00df699c03e8a888e9e94dfbab90b25f39b4
e099bf2a4d557460b5544430bbf6da11004d127cb5d67f64ab07c94fcdf5274f d9c50dbe70d714edb5e221f4e020610eeb6270517e688ca64fb0e98c7ef8c1c5 2beedb04b05c6988f6a67500bb813faf2cae0d580c9253b6339e4a3337bb6c08 3d63e429cb5fa895a9247129bf4e48e89f35d7b11de8158efeb3e106a2a87395 0cae9e477ef41e7c8c1064379bb7b554ddcbcae79f9814281f1e50f0403c61f3 f96e40a1b72840854bb62bc13c40cc2795e373d4e715980b261476835a092e0b
f75a5fe56bda34f3c1396296626ef012dc07e4825838778a645c8248cff01658 33bbdf1b1772d8059df568b061f3f1122f28a8d819167c97be448e3dc3fb0c3c 77c15dcf44610e41696bab758943eff1409333e4d5a11bbe72c8f6c395e9f848 ad5d13c3db508ddcd38457e5991434a251bed49cf5ddcb59cdee73865f138c9f 62cec1e70588aa4fdfc7b9a09daa678081c04e1208b9d662b8a2214bf8e81a21 8388fa79c4babdca02a8e8a34f9e43554976e420a4ad273c81b26e4228e9d3a3
2db4540d50230756158abf61d9835712b6486c74312183ccefcaef2797b7674d 62f57f314e3f3495dc4e099012f5e0ba71770f9660a1eada54104cdfde77243e 42a83b985011d12303db1a800f2610f74aa71cdf19c67d54ce6c9ed951e9093e ab48caa61ea35f13f8ed07ffa6a13e8db224dfecfae1a7df8b1bb6ebaf0cb97d 1274530ca2c385a3218bddfbcbf0b4024c9badd5243bff834ebff24a8618dccb 72877cea33ccc4715038d4bcbdfe0e43f42a9e2c0c3b017fc2370f4b9acbda4a
cd94fc9497e8990750309e9a8534fd114b0a6e54da89c4796101897041d14ecb c3def4b5fe04faee0a11932229fff563637bfdee0e79c6deeaf449f85401c5c4 ceed35507b5c93ead5989119b9ba342cfe38e6e638ba6eea343a55475de2800b 9a8cd9bd72e71752df91440f77c547509a84df98114e7de4f26cdb39234a625d d07cfc84c8e144fab2839f5189bb1d7c88631d579bbc58012ed9a2327da52f62 e4e7408d85ff0e0e9c838003f28cdbd5247cdce31f32f62494b70e5f1bc36307
15b9e467af4d290c417402e040426fe4cf236bae72baa392ed89780dfccdb471 cdf4e9170fb904302b8fd93a820ba8cc7ed4efd3a6f2d6b05b80b2ff2aee4e77 43e0e9d95af4dc36483cdd1968d2b7eeb8611fcce77f3a4e7d059ae43e509604 f989cf8ee956a82e7ebd9881cdbfb2fd946189b08db53559bc8cfdd48071eb14 5eff28f1a18a616b04b7d337868679f6dd84f9a7b3d7b6f8af276c19611a541d ed56bcf695b734142c24ecb1fc1bb64d08f175eb243a31f37b3d9bb4407f3b96
49c503ba6c4fa605182e186b5e81113f075bc11dcfd51c932fb21e951eee2fa1 8af706ff0922d87b3f0c5e4e31d8b259aeb260a9269643ed520a13bb25da5924 b2f3600df3368ef8a0bb85ab22f41fc0e5f4fdd54be8167a5c3cd4b08db04903 69c627625b36a429c398b45c38677cb35d8beb1cf78a571e40e99fe4eac1cd4e 81690112b0a88f20f7136b28d7d47e5fbc2ada3c8edd87589bc19ec9590637bd bc5c7055089fc9d6c89f83c1ea1ada879d9934b2ea28fcf4e4a7e984b28ad2cf
19b38de39fdd2f70f7091631a4f75d1993740ba9429162c2a45312401636b29c 09aed7232b28e060941741b6828bcdfa2bc49cc844f3773611504f82a390a5ae 4002534307f8b62a9bf67ff641ddc60fef593b17c3341239e95bdb3e579bfdc8 5fe964671315a18aa68a2a6e3dd1fde7e23b8ce7181471cfac43c99e1ae80262 d5827be282e62c84de531b963884ba832db5d6b2c3a256f0e604fe7e6b8a7f72 9a4e8e657f6b0e097f47954a63c75d74fcba71a30d83651e3e5a91aa7ccd8343
2c91c61f33adfe9311c942fdbff6ba47020feff416b7bb63cec13faf9b099954 6cab31b06419e5221fca014fb84ec870622a1b12bab5ae43682aa7ea73ea08d0 4dfa12defc60319021b681b3ff84a10a511958c850939ed45635934ba4979147 c9b2b8496f1440bd4a2d1e52752fd372835b364885e154a7dac49295f281ec7c fbe6b926a8a4de26ccc83b802b1212400754be25d9f3eeaf008b09870ae76321 3ca1fc7ad858fb1a6aba232542f3e2a749ffc7203a2374a3f3d3267f1fc97b78
a28a2edf58025668f724aaf83a50956b7ac1cfbbff79b08c3bf87dfd2828d767 dfa7bfffd4c766b86abeaf5c99b6e50cb9ccc9d9d00b7ffc7804b0491b67bc03 1331f6d874a4ed3bc4a2c6e9c74331d3039796314beee3b7152fcdba5556304e 59e1e101521046ad9cf1d082e9d2ec7dd22530cce064991f1e55c5bcf5fcb591 482f4f673176c8fdaa0bb6e59b15a3e47454e3a04297d3863c9338d98add1f37 1aaabe7ee6e4a6fa732291202433a237df1b49bc53866bfbe00db96a0f58224f
a2ef857a081f9d6eb206a81c4cf78a802bdf598ae380c8886ecd85fdc1ed7644 563c4c20419f07bc17d0539fade1855e34839515b892c0f5d26561f97fa04d1a dd5e9f70ae740073ca0204df60763fb6036c45709bf4a7bb4e671412fad65da3 30b9db2e2e977bcdc98cb87dd736cbd8e78552121925cf16e1933657c2fb2314 6a45028800b81291bce5c2e1fed7ded650620ebbe6050c6f3a7f0dfb4673ab5c 430e6a4fba4449d700d2733e557f66a3bf3d50517c1271b1ddae1161b7ac798c
ccd8a2d86bc92f2e01bce4d6922cf7fe1626aed044685e95e2eebd464505f01f e9ddd583a9635a667777d5b8a8f31b0f79eba12c75023410b54b8567dddc0f38 5ae026cfc060d55600717e55b8a12e116d1d0df34af831979057607c2d9c2f76 46c9ebd1a4a3c8c0b6d572b5dcfba12467603208a9cb5d2acfbb733c40cf6391 46c913a27d044185d38b467ace011e04d4d9bbbb8cb9ae25fa92aaf15a595e86 1ce9e6740529499f98d1f1d71329147a33df1d05e4765b539b11cf615d6974d3
c188ffc8947f7301fb7b53e36746097c2134bf9cc981ba74b4e9c4361f595e4e bf7d2f2056e72421ef393f0c0f2b0e00130e3cac4abbcc00286168e85ec55051 b601ac425d5dbf9e1735c5e2d5bdb79ca98b3d5be4a2cfd6f2273f150e064d9d 7c9e950841d26c8dde8994398b8f5d475a022bc63de7773fcf8d552e01f1ba0a cc42b9885c9b3bee0f8d8c57d3a8f6355016c019c4062fa22cff2f209b5cc2e1 4690e3743c07d643f1bc183636ab2a9cb936a60a802113c49bb1b3f2d0661660
317e1020ff53fccef18bf47bb7f2dd7707fb7b7a7578e04f35b3beed222a0eb6 09420ce5a19d77c6fe1ee587e6a49fbaf8f280e8df033d75403302e5a27db2ae fefb1dda1845312b5fce6b81b2be205af2f3a274f5a212f66c0d9fc33d7ae535 38b54db85500cb20c61056edd3d88b6a9dc26780a047f213a6e1b900f76596eb 6387e4e5781571e4eb8ae62991a33b5dc33301c5bc7e125d53794a39160d8fd0 30c2261bd0004e61feda2c16aa5e21ffa8d7e7f7dbf6ec379a43b48e4b36aeb0
45fb02b2ceb9d7c79d9c2fa93e9c7967c2fa4df5789f9640b24264b1e524fcb1 5c6e8ecf1f7d3023893b7b1ca1e4d178972ee2a230757ddc564ffe37f5c5a321 334ae0c4693d23935a7e8e043ebbde21e168a7cba3fa507c9be41d7681e049ce 3f2bf1589abf3047bf3e54ac9a95379bff95f8f55405f64eca36a7eebe8ffca7 5212a94e66c5ae9a8991872f66a72723d80ec5b2e925745c456f5371943b3a06 2adae4a138a239dcd93c243a3803c3e4cf96e37fe14e6a9b717be9599959b11c
a19ef7bff98ada781842fbfc51a47aff39b5935a1c7d9625c8d323d511c92de6 e9c184df75c955e02e02e400ffe45f78f339e1afe6d056fb3245f4700ce606ef 2c4bde40214fcc3bfc47d4cf434b629acbe9157f8fd0282540331de7942cf09d 29c0807f10cbc42fb45c9989da50681eead716daa7b9e91fd32e062f5eb92ca0 ff1d6d1955d7376b2da24fe1163a271659136341bc2eb1195fc706dc62e7f34d 2e277ec30f5ea07d6ce513149b9479b96e07f4b6913b1b5c11305c1444a1bc0b
356c5a444c049a52fee0adeb7e5d82ae5aa83030bfff31bbf8ce2096cf161c4b 57d128de8b2a57a094d1a001e572173f96e8866ae352bf29cddaf92fc85b2f92 85a268f9d7772f990c36b42b0a331adc92b5941de0b862d5d89a347cbf8faab0 9cf4b98581ca1779453cc816ff28b4100af56cf1bf2e5bc312d83b6b1b21d333 7a5504fcac5231a0d12d658218284868229c844a04a3450d6c7381abe080bf3b 1e51373bd2c6044c129c436e742a55be2a668a85ae08441b6756445df5493857
"""
