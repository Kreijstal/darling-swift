#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../../.." && pwd)
out=${CRYPTOKIT_BUILD_DIR:-$here/../build}
: "${OVERLAY_BUILD_DIR:?}" "${DARLING_SOURCE_ROOT:?}"
: "${CRYPTOKIT_SOURCE:?point at the swift-crypto clone used by build.sh}"
mkdir -p "$out/obj"
python3 -I "$here/vectors.py" "$CRYPTOKIT_SOURCE" e8d6eba1fef23ae5b359c46b03f7d94be2f41fed \
 > "$out/vectors.swift"
"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c "$here/main.swift" "$here/p256.swift" "$out/vectors.swift" \
 -target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" \
 -module-cache-path "$out/test-module-cache" -swift-version 5 -module-name CryptoKitAEADTests \
 -I "$out/modules" -I "$OVERLAY_BUILD_DIR/modules" \
 -I "$repo/overlays/CryptoKit" -Xcc -I"$DARLING_SOURCE_ROOT/src/frameworks/CoreServices/include" \
 -Xcc -fmodule-map-file="$repo/overlays/shims/overlay-shims.modulemap" -o "$out/obj/tests.o"
"$DARLING_LD" -arch arm64 -platform_version macos 26.0 26.0 -syslibroot "$DARLING_SDK" \
 ${LD_EXTRA_FLAGS:-} -L "$SWIFT_RESOURCE_DIR/macosx" -L "$repo" \
 "${DARLING_CRT1:?path to the Darling arm64 crt1 start.S.o}" \
 "$out/obj/tests.o" "$out/CryptoKit" "$DARLING_LIBSYSTEM" \
 "$DARLING_ROOT/usr/lib/libobjc.A.dylib" \
 "$DARLING_ROOT/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation" \
 "$DARLING_ROOT/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation" \
 "$DARLING_ROOT/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork" \
 -lswiftCore -lswiftFoundation -lswiftCoreFoundation -lswiftDarwin -lswiftObjectiveC \
 -o "$out/cryptokit-tests"

mkdir -p "$out/CryptoKit.framework/Versions/A"
ln -sfn ../../../CryptoKit "$out/CryptoKit.framework/Versions/A/CryptoKit"
ln -sfn A "$out/CryptoKit.framework/Versions/Current"
ln -sfn Versions/Current/CryptoKit "$out/CryptoKit.framework/CryptoKit"
printf '%s\n' "$out/cryptokit-tests"
