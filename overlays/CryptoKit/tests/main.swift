import Foundation
import Darwin
import CryptoKit

func hex(_ text: String) -> Data {
    let chars = Array(text)
    precondition(chars.count % 2 == 0)
    return Data(stride(from: 0, to: chars.count, by: 2).map {
        UInt8(String(chars[$0...$0 + 1]), radix: 16)!
    })
}

func rejects(_ body: () throws -> Void) {
    do {
        try body()
        fatalError("accepted invalid authenticated ciphertext")
    } catch {}
}

// NIST GCM vectors: zero key, zero 96-bit IV, empty plaintext.
for (length, expected) in [
    (16, "58e2fccefa7e3061367f1d57a4e7455a"),
    (24, "cd33b28ac773f74ba00ed1f312572435"),
    (32, "530f8afbc74536b9a963b4f1c4cb738b")
] {
    let key = SymmetricKey(data: Data(repeating: 0, count: length))
    let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
    let sealed = try AES.GCM.seal(Data(), using: key, nonce: nonce)
    precondition(sealed.tag == hex(expected))
    let opened = try AES.GCM.open(sealed, using: key)
    precondition(opened == Data())
}

let aesKey = SymmetricKey(data: Data(repeating: 0, count: 16))
let aesNonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
let aes = try AES.GCM.seal(Data(repeating: 0, count: 16), using: aesKey, nonce: aesNonce)
precondition(aes.ciphertext == hex("0388dace60b6a392f328c2b971b2fe78"))
precondition(aes.tag == hex("ab6e47d42cec13bdf53a67b21257bddf"))
var badTag = aes.tag
badTag[badTag.startIndex] ^= 1
let badAES = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: aes.ciphertext, tag: badTag)
rejects { _ = try AES.GCM.open(badAES, using: aesKey) }
print("AES-GCM: NIST vectors for 128/192/256-bit keys and tamper rejection pass")

// RFC 8439 section 2.8.2.
let key = SymmetricKey(data: hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
let nonce = try ChaChaPoly.Nonce(data: hex("070000004041424344454647"))
let aad = hex("50515253c0c1c2c3c4c5c6c7")
let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
let expected = hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116")
let chacha = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
precondition(chacha.ciphertext == expected)
precondition(chacha.tag == hex("1ae10b594f09e26a7e902ecbd0600691"))
let openedChaCha = try ChaChaPoly.open(chacha, using: key, authenticating: aad)
precondition(openedChaCha == plaintext)
rejects { _ = try ChaChaPoly.open(chacha, using: key, authenticating: Data()) }
var alteredTag = chacha.tag
alteredTag[alteredTag.startIndex] ^= 1
let badChaCha = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: chacha.ciphertext, tag: alteredTag)
rejects { _ = try ChaChaPoly.open(badChaCha, using: key, authenticating: aad) }
print("ChaCha20-Poly1305: RFC 8439 encryption, decryption, AAD and tag rejection pass")

rejects { _ = try AES.GCM.seal(Data(), using: SymmetricKey(data: Data(repeating: 0, count: 7))) }
rejects { _ = try ChaChaPoly.seal(Data(), using: SymmetricKey(data: Data(repeating: 0, count: 31))) }
rejects { _ = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 11)) }
precondition(Data(SHA256.hash(data: Data("abc".utf8))) == hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
print("Key/nonce validation and existing SHA256 behavior pass")

// P-256: the curve's base point G (SEC 2 section 2.4.2) is a valid public key.
let gx = hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
let gy = hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
let g963 = Data([4]) + gx + gy
let g = try P256.KeyAgreement.PublicKey(x963Representation: g963)
precondition(g.x963Representation == g963)
precondition(g.rawRepresentation == gx + gy)
precondition(g.compressedRepresentation == Data([3]) + gx)
let fromRaw = try P256.KeyAgreement.PublicKey(rawRepresentation: gx + gy)
precondition(fromRaw.x963Representation == g963)
let fromCompressed = try P256.KeyAgreement.PublicKey(compressedRepresentation: Data([3]) + gx)
precondition(fromCompressed.x963Representation == g963)
var offCurve = g963
offCurve[offCurve.endIndex - 1] ^= 1
rejects { _ = try P256.KeyAgreement.PublicKey(x963Representation: offCurve) }
rejects { _ = try P256.KeyAgreement.PublicKey(x963Representation: g963.dropLast()) }
rejects { _ = try P256.KeyAgreement.PublicKey(x963Representation: Data(repeating: 0, count: 65)) }
print("P256.KeyAgreement.PublicKey: X9.63, raw and compressed forms, off-curve and size rejection pass")

// FIPS 180-4 and RFC 1321 "abc" vectors, the empty message, and a stream fed
// in uneven pieces across the block boundary.
let abc = Data("abc".utf8)
precondition(Data(SHA384.hash(data: abc)) == hex("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"))
precondition(Data(SHA512.hash(data: abc)) == hex("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"))
precondition(Data(Insecure.SHA1.hash(data: abc)) == hex("a9993e364706816aba3e25717850c26c9cd0d89d"))
precondition(Data(Insecure.MD5.hash(data: abc)) == hex("900150983cd24fb0d6963f7d28e17f72"))
precondition(Data(Insecure.MD5.hash(data: Data())) == hex("d41d8cd98f00b204e9800998ecf8427e"))
precondition(Data(SHA512.hash(data: Data())) == hex("cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"))
let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
var streamed = SHA512()
var offset = 0
for size in [1, 7, 127, 128, 129, 1000] where offset < million.count {
    streamed.update(data: million[offset..<offset + size]); offset += size
}
let half = streamed
streamed.update(data: million[offset...])
precondition(Data(streamed.finalize()) == hex("e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"))
precondition(Data(half.finalize()) == Data(SHA512.hash(data: million[..<offset])))
precondition(Data(Insecure.SHA1.hash(data: million)) == hex("34aa973cd4c4daa4f61eeb2bdbad27316534016f"))
let mac = HMAC<SHA512>.authenticationCode(for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
precondition(Data(mac) == hex("164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"))
print("SHA384, SHA512, Insecure.SHA1 and Insecure.MD5 pass")
