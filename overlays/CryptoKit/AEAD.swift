import Foundation
@_implementationOnly import DarlingAEAD

private func crypt<N: ContiguousBytes>(encrypt: Bool, aes: Bool, key: SymmetricKey,
    nonce: N, input: Data, aad: Data) throws -> Data {
    guard input.count <= Int(Int32.max) - 16, aad.count <= Int(Int32.max) else {
        throw CryptoKitError.incorrectParameterSize
    }
    var output = [UInt8](repeating: 0, count: max(1, input.count + 16))
    let count = output.withUnsafeMutableBytes { out in
        key.withUnsafeBytes { k in
            nonce.withUnsafeBytes { n in
                input.withUnsafeBytes { bytes in
                    aad.withUnsafeBytes { ad in
                        darling_crypto_aead(encrypt ? 1 : 0, aes ? 1 : 0,
                            k.baseAddress, k.count, n.baseAddress, n.count,
                            bytes.baseAddress, bytes.count, ad.baseAddress, ad.count,
                            out.baseAddress)
                    }
                }
            }
        }
    }
    guard count >= 0 else {
        if encrypt { throw CryptoKitError.underlyingCoreCryptoError(error: -1) }
        throw CryptoKitError.authenticationFailure
    }
    return Data(output.prefix(Int(count)))
}

enum OpenSSLChaChaPolyImpl {
    static func encrypt<M: DataProtocol, AD: DataProtocol>(key: SymmetricKey,
        message: M, nonce: ChaChaPoly.Nonce?, authenticatedData: AD?) throws -> ChaChaPoly.SealedBox {
        guard key.bitCount == 256 else { throw CryptoKitError.incorrectKeySize }
        let nonce = nonce ?? ChaChaPoly.Nonce()
        let aad = authenticatedData.map { Data($0) } ?? Data()
        let sealed = try crypt(encrypt: true, aes: false, key: key, nonce: nonce,
            input: Data(message), aad: aad)
        return try ChaChaPoly.SealedBox(nonce: nonce,
            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
    }

    static func decrypt<AD: DataProtocol>(key: SymmetricKey, ciphertext: ChaChaPoly.SealedBox,
        authenticatedData: AD?) throws -> Data {
        guard key.bitCount == 256 else { throw CryptoKitError.incorrectKeySize }
        return try crypt(encrypt: false, aes: false, key: key, nonce: ciphertext.nonce,
            input: ciphertext.ciphertext + ciphertext.tag,
            aad: authenticatedData.map { Data($0) } ?? Data())
    }
}

enum OpenSSLAESGCMImpl {
    static func seal<M: DataProtocol, AD: DataProtocol>(key: SymmetricKey,
        message: M, nonce: AES.GCM.Nonce?, authenticatedData: AD?) throws -> AES.GCM.SealedBox {
        guard AES.isValidKey(key) else { throw CryptoKitError.incorrectKeySize }
        let nonce = nonce ?? AES.GCM.Nonce()
        let sealed = try crypt(encrypt: true, aes: true, key: key, nonce: nonce,
            input: Data(message), aad: authenticatedData.map { Data($0) } ?? Data())
        return try AES.GCM.SealedBox(nonce: nonce,
            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
    }

    static func open<AD: DataProtocol>(key: SymmetricKey, sealedBox: AES.GCM.SealedBox,
        authenticatedData: AD?) throws -> Data {
        guard AES.isValidKey(key) else { throw CryptoKitError.incorrectKeySize }
        return try crypt(encrypt: false, aes: true, key: key, nonce: sealedBox.nonce,
            input: sealedBox.ciphertext + sealedBox.tag,
            aad: authenticatedData.map { Data($0) } ?? Data())
    }
}
