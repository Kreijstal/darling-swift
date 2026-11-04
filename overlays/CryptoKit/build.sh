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
# 3.12.3, before span-only API additions: the stable AEAD APIs Roon imports.
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
Sources/Crypto/Insecure/Insecure_HashFunctions.swift
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
SOURCES
printf '"%s"\n' "$here/AEAD.swift" "$here/HashFunctions_LibreSSL.swift" >> "$out/sources"

rm -f "$out/obj/AEAD.o" "$out/obj/Digests.o" "$out/obj/CryptoKit.o" "$out/CryptoKit"
"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 -isysroot "$DARLING_SDK" \
    -I "$DARLING_SOURCE_ROOT/src/external/libressl-2.8.3/include" \
    -O2 -c "$here/aead.c" -o "$out/obj/AEAD.o"
"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 -isysroot "$DARLING_SDK" \
    -I "$DARLING_SOURCE_ROOT/src/external/libressl-2.8.3/include" \
    -O2 -c "$here/digests.c" -o "$out/obj/Digests.o"
"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c @"$out/sources" \
    -target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" \
    -module-cache-path "$out/module-cache" -swift-version 5 -module-name CryptoKit \
    -D DARLING_CRYPTOKIT_MODULE -D CRYPTO_IN_SWIFTPM_FORCE_BUILD_API \
    -enable-experimental-feature Lifetimes -enable-library-evolution -parse-as-library -O \
    -I "$OVERLAY_BUILD_DIR/modules" -I "$here" \
    -Xcc -I"$DARLING_SOURCE_ROOT/src/frameworks/CoreServices/include" \
    -Xcc -fmodule-map-file="$repo/overlays/shims/overlay-shims.modulemap" \
    -emit-module-path "$out/modules/CryptoKit.swiftmodule" -o "$out/obj/CryptoKit.o"

# LD_EXTRA_FLAGS contains the same install-name mappings as the runtime's link.
# shellcheck disable=SC2086
"$DARLING_LD" -dylib -arch arm64 -platform_version macos 26.0 26.0 \
    -syslibroot "$DARLING_SDK" \
    -install_name /System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit \
    -compatibility_version 1.0.0 -current_version 1.0.0 \
    ${LD_EXTRA_FLAGS:-} -L "$SWIFT_RESOURCE_DIR/macosx" -L "$repo" \
    "$out/obj/CryptoKit.o" "$out/obj/AEAD.o" "$out/obj/Digests.o" "$DARLING_LIBSYSTEM" \
    "$DARLING_ROOT/usr/lib/libobjc.A.dylib" "$DARLING_ROOT/usr/lib/libcrypto.44.dylib" \
    -lswiftCore -lswiftFoundation -lswiftCoreFoundation -lswiftDarwin -lswiftObjectiveC \
    -o "$out/CryptoKit"
