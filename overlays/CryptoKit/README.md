# AEAD support for the Darling CryptoKit framework

The shipped CryptoKit subset supplies SHA256 and HMAC. This focused build retains
that source and adds the public AES-GCM and ChaCha20-Poly1305 API declarations from
upstream swift-crypto 3.12.3. Both source revisions are pinned in `build.sh`; source
files are extracted into the build directory without modifying the supplied clone.
The upstream files retain their Apache-2.0 notices. `AEAD.swift` routes the APIs to
the runtime's existing LibreSSL implementation through `aead.c`.

The bridge returns failure when authentication fails and clears partial plaintext.
It supports AES keys of 128, 192 and 256 bits and 256-bit ChaCha20 keys.

`HashFunctions_LibreSSL.swift` adds `SHA384`, `SHA512`, `Insecure.SHA1` and
`Insecure.MD5` (the last two from upstream `Insecure_HashFunctions.swift` at the
base pin), hashed by LibreSSL through `digests.c`. Feather 2.9.0 binds SHA512,
SHA1 and MD5. The fixture checks the FIPS 180-4 and RFC 1321 vectors, a
one-million-byte stream fed in uneven pieces, a copied half-fed hash, and RFC
4231 HMAC-SHA-512. The current C backend links libcrypto.44.

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
and the existing SHA256 API. Compile it against the emitted CryptoKit module and
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
