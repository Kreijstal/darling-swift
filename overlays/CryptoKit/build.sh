#!/bin/sh
set -eu
: "${SWIFT_TOOLCHAIN:?}" "${SWIFT_RESOURCE_DIR:?}" "${DARLING_SDK:?}"
: "${DARLING_LD:?}" "${DARLING_LIBSYSTEM:?}" "${DARLING_ROOT:?}"
: "${CRYPTOKIT_SOURCE:?point at a swift-crypto clone containing the pinned commits}"
: "${OVERLAY_BUILD_DIR:?contains the rebuilt Foundation Swift module}"
: "${DARLING_SOURCE_ROOT:?}"
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
out=${CRYPTOKIT_BUILD_DIR:-$here/build}
mkdir -p "$out/src" "$out/obj" "$out/modules"

# The first pin is this runtime's SHA256/HMAC source. The second is upstream tag
# 3.12.3, before span-only API additions: the stable AEAD APIs Roon imports, and
# the P-256, SharedSecret, HKDF and ASN.1 sources.
base=c4105ade5fbe6866375ec65146cac733d53a1146
aead=e8d6eba1fef23ae5b359c46b03f7d94be2f41fed
: > "$out/sources"
while read -r relative; do
    [ -n "$relative" ] || continue
    destination="$out/src/$relative"
    mkdir -p "$(dirname "$destination")"
    git -C "$CRYPTOKIT_SOURCE" show "$base:$relative" > "$destination"
    printf '"%s"\n' "$destination" >> "$out/sources"
done <<'SOURCES'
Sources/Crypto/Digests/Digest.swift
Sources/Crypto/Digests/Digests.swift
Sources/Crypto/Digests/HashFunctions.swift
Sources/Crypto/Digests/HashFunctions_SHA2.swift
Sources/Crypto/Digests/Darling/Digest_darling.swift
Sources/Crypto/Keys/Symmetric/SymmetricKeys.swift
Sources/Crypto/Insecure/Insecure.swift
Sources/Crypto/Util/ArraySpanHelpers.swift
Sources/Crypto/Util/Data+ArraySpan.swift
Sources/Crypto/Util/PrettyBytes.swift
Sources/Crypto/Util/SafeCompare.swift
Sources/Crypto/Util/SecureBytes.swift
Sources/Crypto/Util/Zeroization.swift
Sources/Crypto/Util/BoringSSL/SafeCompare_boring.swift
Sources/Crypto/Util/BoringSSL/RNG_boring.swift
Sources/Crypto/Util/BoringSSL/InlineArray+withBytes_boring.swift
Sources/Crypto/Util/BoringSSL/Optional+withUnsafeBytes_boring.swift
Sources/Crypto/Message Authentication Codes/HMAC/HMAC.swift
Sources/Crypto/Message Authentication Codes/MessageAuthenticationCode.swift
Sources/Crypto/Message Authentication Codes/MACFunctions.swift
Sources/Crypto/CryptoKitErrors.swift
SOURCES

while read -r relative; do
    destination="$out/src/$relative"
    mkdir -p "$(dirname "$destination")"
    git -C "$CRYPTOKIT_SOURCE" show "$aead:$relative" > "$destination"
    printf '"%s"\n' "$destination" >> "$out/sources"
done <<'SOURCES'
Sources/Crypto/PRF/AES.swift
Sources/Crypto/AEADs/Cipher.swift
Sources/Crypto/AEADs/Nonces.swift
Sources/Crypto/AEADs/AES/GCM/AES-GCM.swift
Sources/Crypto/AEADs/ChachaPoly/ChaChaPoly.swift
Sources/Crypto/Signatures/Signature.swift
Sources/Crypto/Key Agreement/DH.swift
Sources/Crypto/Key Derivation/HKDF.swift
Sources/Crypto/ASN1/ASN1.swift
Sources/Crypto/ASN1/ECDSASignature.swift
Sources/Crypto/ASN1/PEMDocument.swift
Sources/Crypto/ASN1/PKCS8PrivateKey.swift
Sources/Crypto/ASN1/SEC1PrivateKey.swift
Sources/Crypto/ASN1/SubjectPublicKeyInfo.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ArraySliceBigint.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1Any.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1BitString.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1Boolean.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1Identifier.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1Integer.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1Null.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1OctetString.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ASN1Strings.swift
Sources/Crypto/ASN1/Basic ASN1 Types/GeneralizedTime.swift
Sources/Crypto/ASN1/Basic ASN1 Types/ObjectIdentifier.swift
SOURCES

# P-256 only: these generated files also declare P-384, P-521 and Curve25519, which
# need SHA-384/512 and backends this build lacks. Each line is a path, a tab, and the
# sed script that keeps the license header, the P-256 declarations and the final #endif.
tab=$(printf '\t')
while IFS="$tab" read -r relative script; do
    destination="$out/src/$relative"
    mkdir -p "$(dirname "$destination")"
    git -C "$CRYPTOKIT_SOURCE" show "$aead:$relative" | sed -n "$script" > "$destination"
    if grep -qE 'P384|P521|Curve25519' "$destination" ||
        [ "$(tail -n 1 "$destination")" != "#endif // Linux or !SwiftPM" ]; then
        echo "unexpected content in sliced $relative; check the pin" >&2
        exit 1
    fi
    printf '"%s"\n' "$destination" >> "$out/sources"
done <<'SOURCES'
Sources/Crypto/Keys/EC/NISTCurvesKeys.swift	1,58p;66p
Sources/Crypto/Key Agreement/ECDH.swift	1,471p;1347,1363p;1398p
Sources/Crypto/Signatures/ECDSA.swift	1,206p;548p
Sources/Crypto/Signatures/Ed25519.swift	1,30p;80p
SOURCES
printf '"%s"\n' "$here/AEAD.swift" >> "$out/sources"
printf '"%s"\n' "$here/ECC.swift" >> "$out/sources"

rm -f "$out/obj/AEAD.o" "$out/obj/ECC.o" "$out/obj/CryptoKit.o" "$out/CryptoKit"
"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 -isysroot "$DARLING_SDK" \
    -I "$DARLING_SOURCE_ROOT/src/external/libressl-2.8.3/include" \
    -O2 -c "$here/aead.c" -o "$out/obj/AEAD.o"
"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 -isysroot "$DARLING_SDK" \
    -I "$DARLING_SOURCE_ROOT/src/external/libressl-2.8.3/include" \
    -O2 -c "$here/ecc.c" -o "$out/obj/ECC.o"
"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c @"$out/sources" \
    -target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" \
    -module-cache-path "$out/module-cache" -swift-version 5 -module-name CryptoKit \
    -D DARLING_CRYPTOKIT_MODULE -D CRYPTO_IN_SWIFTPM_FORCE_BUILD_API \
    -enable-experimental-feature Lifetimes -enable-library-evolution -parse-as-library -O \
    -I "$OVERLAY_BUILD_DIR/modules" -I "$here" \
    -Xcc -I"$DARLING_SOURCE_ROOT/src/frameworks/CoreServices/include" \
    -Xcc -fmodule-map-file="$repo/overlays/shims/overlay-shims.modulemap" \
    -emit-module-path "$out/modules/CryptoKit.swiftmodule" -o "$out/obj/CryptoKit.o"

# Foundation.framework: the PEM code's Data(base64Encoded:) is inlined from the
# Foundation overlay and references NSData directly.
# LD_EXTRA_FLAGS contains the same install-name mappings as the runtime's link.
# shellcheck disable=SC2086
"$DARLING_LD" -dylib -arch arm64 -platform_version macos 26.0 26.0 \
    -syslibroot "$DARLING_SDK" \
    -install_name /System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit \
    -compatibility_version 1.0.0 -current_version 1.0.0 \
    ${LD_EXTRA_FLAGS:-} -L "$SWIFT_RESOURCE_DIR/macosx" -L "$repo" \
    "$out/obj/CryptoKit.o" "$out/obj/AEAD.o" "$out/obj/ECC.o" "$DARLING_LIBSYSTEM" \
    "$DARLING_ROOT/usr/lib/libobjc.A.dylib" "$DARLING_ROOT/usr/lib/libcrypto.44.dylib" \
    "$DARLING_ROOT/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation" \
    "$DARLING_ROOT/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation" \
    "$DARLING_ROOT/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork" \
    -lswiftCore -lswiftFoundation -lswiftCoreFoundation -lswiftDarwin -lswiftObjectiveC \
    -o "$out/CryptoKit"
