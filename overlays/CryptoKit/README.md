# AEAD and P-256 support for the Darling CryptoKit framework

The shipped CryptoKit subset supplies SHA256 and HMAC. This focused build retains
that source and adds the public AES-GCM and ChaCha20-Poly1305 API declarations from
upstream swift-crypto 3.12.3. Both source revisions are pinned in `build.sh`; source
files are extracted into the build directory without modifying the supplied clone.
The upstream files retain their Apache-2.0 notices. `AEAD.swift` routes the APIs to
the runtime's existing LibreSSL implementation through `aead.c`.

The bridge returns failure when authentication fails and clears partial plaintext.
It supports AES keys of 128, 192 and 256 bits and 256-bit ChaCha20 keys. The
current C backend links libcrypto.44.

P-256 signing (ECDSA), key agreement (ECDH), `SharedSecret` with x9.63 and HKDF
derivation, and `HKDF` itself also come from swift-crypto 3.12.3, so the
declarations (and their mangled names) are swift-crypto's. These files are used
whole: `Signatures/Signature.swift`, `Key Agreement/DH.swift`,
`Key Derivation/HKDF.swift`, and `ASN1/` (`ASN1.swift`, `ECDSASignature.swift`,
`PEMDocument.swift`, `PKCS8PrivateKey.swift`, `SEC1PrivateKey.swift`,
`SubjectPublicKeyInfo.swift` and the eleven `Basic ASN1 Types` files). Four
generated files are cut to their P-256 line ranges with `sed -n`, bytes unchanged:
`Keys/EC/NISTCurvesKeys.swift` (1-58, 66), `Key Agreement/ECDH.swift` (1-471,
1347-1363, 1398), `Signatures/ECDSA.swift` (1-206, 548) and
`Signatures/Ed25519.swift` (1-30, 80, the validator protocols only). `build.sh`
fails if a slice mentions P384, P521 or Curve25519 or does not end in the file's
closing `#endif`. `ECC.swift` supplies the backend names those files select and
routes them through `ecc.c` to the runtime's LibreSSL. That library must include
`-fno-strict-aliasing` (LibreSSL submodule commit 470abfc) for EC arithmetic to be
correct. The backend was written against LibreSSL 2.8.3's manual pages and
headers; no binary implementation was inspected. Because the PEM code inlines the
Foundation overlay's `Data(base64Encoded:)`, which references `NSData`, the
framework now also links Foundation, CoreFoundation and CFNetwork from
`DARLING_ROOT`.

Not included: P-384 and P-521 (this CryptoKit has no SHA-384/512), Curve25519,
SecureEnclave and HPKE. Differences from swift-crypto's BoringSSL backend: a
missing compact square root throws `CryptoKitError.underlyingCoreCryptoError`,
not a `CryptoBoringWrapperError`, and every backend failure reports error -1.
Compact representability follows swift-crypto's own test, `y <= (n - y) mod p`
with n the group order, rather than draft-jivsov-ecc-compact's `y <= p - y`.

Use the same environment as `../build.sh`, plus:

- `DARLING_SOURCE_ROOT`: the Darling superproject checkout.
- `CRYPTOKIT_SOURCE`: a clone of `https://github.com/cristim/swift-crypto.git`
  containing base commit `c4105ade5fbe6866375ec65146cac733d53a1146` and upstream
  3.12.3 commit `e8d6eba1fef23ae5b359c46b03f7d94be2f41fed`.
  The base includes the runtime's existing Darling SHA256/HMAC backend.
- `OVERLAY_BUILD_DIR`: an overlay build containing the Foundation Swift module.
- `CRYPTOKIT_BUILD_DIR`: optional separate output directory.

Run `sh build.sh`. The output is `CryptoKit` in the build directory; the shipped
framework is not replaced automatically. `tests/main.swift` checks NIST GCM
vectors, RFC 8439 section 2.8.2, authentication rejection, key and nonce validation,
and the existing SHA256 API. `tests/p256.swift` checks RFC 6979 A.2.5, RFC 4754
section 8.1, the NIST CAVP KAS ECC CDH P-256 vectors, Wycheproof ECDSA and ECDH
(Apache-2.0), RFC 5869 and the CAVS x9.63 KDF. The Wycheproof, RFC 5869 and CAVS
files are extracted at test time from the swift-crypto pin by `tests/vectors.py`,
not vendored, so `tests/run.sh` also needs `CRYPTOKIT_SOURCE` and `python3`. Compile it against the emitted CryptoKit module and
run it under the same Darling prefix that will run the application.

The motivating imports came from the unmodified Roon 2.74 build 1712 guest's
`libSystem.Security.Cryptography.Native.Apple.dylib`, using only `llvm-nm -u -m`
for interface names. No binary implementation was inspected.

To include the generated executable in a staged Darling installation, configure
Darling with `-DDARLING_CRYPTOKIT_BINARY=/absolute/build/path/CryptoKit` after this
build completes, then use its normal staged install. This arm64-only option
changes the executable installed in the existing versioned framework layout;
it does not commit or copy compiled output into the source tree. Without the
option, installation retains the repository's existing prebuilt subset.

Run `sh tests/run.sh` with the same environment to compile the authored vector
fixture. It prints the executable path; run that executable under Darling with
this build directory supplied through `DYLD_FRAMEWORK_PATH` (the script creates
the framework layout). No application data or secret test keys are used.
