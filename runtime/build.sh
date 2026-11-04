#!/bin/sh
# Rebuild the arm64 slices of the Swift runtime libraries in this repository from Swift's open
# source, so that they run on any ARMv8.0-A CPU, and merge each with the x86_64 slice already here.
# See README.md for the reasoning and how to check the result.
#
# Every C, C++, assembly and Swift file is compiled for arm64-apple-macosx13.0 with
# -mcpu=apple-a7 -moutline-atomics (macos-arm64.cmake). Without -mcpu, clang picks apple-m1 for
# an arm64-apple-macosx target, a CPU with the Armv8.1-A LSE atomics and the RCpc loads, which an
# ARMv8.0 core such as the Cortex-A72 does not implement. apple-a7 is ARMv8.0-A. With
# -moutline-atomics each atomic operation becomes a call to one of compiler-rt's helpers, which
# use LSE only when the CPU has it.
#
# Built: libswiftCore, libswift_Concurrency, libswiftSwiftOnoneSupport, libswiftRemoteMirror
# (Runtimes/Core); libswift_Builtin_float (Runtimes/Overlay); libswift_StringProcessing,
# libswift_RegexParser, libswiftRegexBuilder, libswiftSynchronization, libswift_Volatile,
# libswiftObservation, libswiftDistributed and libswift_Differentiation (Runtimes/Supplemental);
# libswiftCompatibilitySpan.dylib is a symlink to libswiftCore.dylib. Not built:
# libswiftRuntime (Runtimes/Supplemental/Runtime), which is compiled in C++ interoperability mode
# and so needs the CxxStdlib overlay, whose libc++ module (std) does not build against Darling's
# SDK; see README.md.
#
# Required environment:
#   SWIFT_TOOLCHAIN  usr/ of a Swift 6.3.3 toolchain (the Linux release works); only its swiftc is
#                    used, and clang, ld64.lld, llvm-ar, llvm-lipo and llvm-objdump come from PATH
#                    (ld64.lld must support Mach-O for macOS: the Swift Linux toolchain's does not)
#   DARLING_ROOT     an installed Darling root; its usr/lib (except usr/lib/swift) is linked against
#   DARLING_SDK      Darling's MacOSX.sdk (Developer/Platforms/MacOSX.platform/Developer/SDKs)
#   CXX_HEADERS      a directory whose v1/ holds the libc++ headers (Darling's
#                    src/external/libcxx/include, which carries its __config_site)
# Optional:
#   WORK             build directory (default runtime/build)
#   JOBS             parallel jobs (default nproc)
#   SWIFT_SRC, STRING_PROCESSING_SRC, LLVM_SRC
#                    existing checkouts of the pinned commits below, for an offline build. Nothing
#                    checks them, so point them at those commits. Swift's Runtimes/Resync.cmake
#                    writes into SWIFT_SRC, so it must be writable.
#   MERGE_X86_64=0   stop after the check, leaving the arm64 libraries in $WORK/arm64

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
: "${SWIFT_TOOLCHAIN:?}" "${DARLING_ROOT:?}" "${DARLING_SDK:?}" "${CXX_HEADERS:?}"
WORK=${WORK:-$here/build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
JOBS=${JOBS:-$(nproc)}

# fetch <url> <commit> <dir>: a checkout of one commit, the way ../overlays/build.sh fetches.
fetch() {
	if [ ! -d "$3/.git" ]; then
		mkdir -p "$3"
		git -C "$3" init --quiet
		git -C "$3" remote add origin "$1"
	fi
	git -C "$3" fetch --quiet --depth 1 --filter=blob:none origin "$2"
	git -C "$3" checkout --quiet --detach "$2"
}

# Pinned BY COMMIT. 064859e4... is tag swift-6.3.3-RELEASE (a lightweight tag); check with
#   git ls-remote https://github.com/swiftlang/swift.git refs/tags/swift-6.3.3-RELEASE
SWIFT_COMMIT=064859e41d68596f486c5d724401cb370f260409
# efe89868... is tag swift-6.3.3-RELEASE; check with
#   git ls-remote https://github.com/swiftlang/swift-experimental-string-processing.git refs/tags/swift-6.3.3-RELEASE
STRING_PROCESSING_COMMIT=efe8986824694c53fd5e94a4c634f20b3682baeb
# 2078da43... is tag llvmorg-21.1.8; check with
#   git ls-remote https://github.com/llvm/llvm-project.git 'refs/tags/llvmorg-21.1.8^{}'
# Only compiler-rt/lib/builtins/{aarch64/lse.S,assembly.h,os_version_check.c} are used.
LLVM_COMMIT=2078da43e25a4623cab2d0d60decddf709aaea28

swift_src=${SWIFT_SRC:-$WORK/swift}
[ -n "${SWIFT_SRC:-}" ] || fetch https://github.com/swiftlang/swift.git "$SWIFT_COMMIT" "$swift_src"
sp_root=${STRING_PROCESSING_SRC:+$(dirname "$STRING_PROCESSING_SRC")}
if [ -z "$sp_root" ]; then
	sp_root=$WORK/deps
	fetch https://github.com/swiftlang/swift-experimental-string-processing.git "$STRING_PROCESSING_COMMIT" \
		"$sp_root/swift-experimental-string-processing"
fi
llvm_src=${LLVM_SRC:-$WORK/llvm-project}
if [ -z "${LLVM_SRC:-}" ]; then
	if [ ! -d "$llvm_src/.git" ]; then
		mkdir -p "$llvm_src"
		git -C "$llvm_src" init --quiet
		git -C "$llvm_src" remote add origin https://github.com/llvm/llvm-project.git
		git -C "$llvm_src" sparse-checkout set --no-cone compiler-rt/lib/builtins/aarch64/lse.S \
			compiler-rt/lib/builtins/assembly.h compiler-rt/lib/builtins/os_version_check.c
	fi
	git -C "$llvm_src" fetch --quiet --depth 1 --filter=blob:none origin "$LLVM_COMMIT"
	git -C "$llvm_src" checkout --quiet --detach FETCH_HEAD
fi
builtins_src=$llvm_src/compiler-rt/lib/builtins

# The standalone runtime build (Runtimes/) takes its sources from stdlib/ by this upstream script.
cmake -DStringProcessing_ROOT_DIR="$sp_root" -P "$swift_src/Runtimes/Resync.cmake" > "$WORK/resync.log"

# The sysroot: Darling's SDK, plus libc++ headers, plus Darling's built libraries to link with.
# CoreServices' subframeworks (AE...) go into Library/Frameworks, where clang finds them by name.
# usr/lib/swift holds what the Supplemental libraries look for in an SDK (Darwin).
sdk=$WORK/sdk
rm -rf "$sdk"
mkdir -p "$sdk/usr/include" "$sdk/usr/lib/swift" "$sdk/System/Library" "$sdk/Library/Frameworks"
for e in "$DARLING_SDK"/usr/include/*; do ln -s "$(readlink -f "$e")" "$sdk/usr/include/$(basename "$e")"; done
ln -s "$CXX_HEADERS" "$sdk/usr/include/c++"
ln -s "$DARLING_SDK/System/Library/Frameworks" "$sdk/System/Library/Frameworks"
for f in "$DARLING_SDK"/System/Library/Frameworks/*.framework/Frameworks/*.framework \
	"$DARLING_SDK"/System/Library/Frameworks/*.framework/Versions/*/Frameworks/*.framework; do
	[ -e "$f" ] || continue
	[ -e "$sdk/Library/Frameworks/$(basename "$f")" ] || ln -s "$(readlink -f "$f")" "$sdk/Library/Frameworks/"
done
for e in "$DARLING_ROOT"/usr/lib/*; do
	[ "$(basename "$e")" = swift ] || ln -s "$e" "$sdk/usr/lib/"
done
# Observation imports Darwin.os.lock and _Differentiation imports Darwin.C.tgmath
# (Runtimes/Supplemental/Observation/Sources/Observation/Locking.swift and
# Runtimes/Supplemental/Differentiation/TgmathDerivatives.swift.gyb). Darling's Darwin module is
# one umbrella without those submodules, so the sysroot gets a copy of its module map that adds
# them. tgmath.h is clang's builtin header, found through -fbuiltin-headers-in-system-modules.
rm "$sdk/usr/include/module.modulemap"
awk '{ print } /^module Darwin / && !done { print "  module os {\n    module lock {\n      header \"os/lock.h\"\n      export *\n    }\n  }\n  module C {\n    module tgmath {\n      header \"tgmath.h\"\n      export *\n    }\n  }"; done = 1 }' \
	"$DARLING_SDK/usr/include/module.modulemap" > "$sdk/usr/include/module.modulemap"
grep -q 'module tgmath' "$sdk/usr/include/module.modulemap" || { echo "module map: Darwin submodules not added" >&2; exit 1; }
cat > "$sdk/SDKSettings.json" <<'EOF'
{"CanonicalName":"macosx15.2","DisplayName":"macOS 15.2","Version":"15.2","MaximumDeploymentTarget":"15.2.99","IsBaseSDK":"YES","DefaultDeploymentTarget":"15.2","SupportedTargets":{"macosx":{"Archs":["arm64","x86_64"],"LLVMTargetTripleVendor":"apple","LLVMTargetTripleSys":"macosx","DefaultDeploymentTarget":"15.2","MinimumDeploymentTarget":"10.13","MaximumDeploymentTarget":"15.2.99","PlatformFamilyName":"macOS"}}}
EOF

# compiler-rt builtins, which the libraries need and the sysroot does not provide: the outline
# atomics helpers (lse.S, assembled once per operation, size and memory order), the flag they test
# (outline-atomics-init.c, written for Darling) and __isPlatformVersionAtLeast & co.
# (os_version_check.c), which clang calls for @available checks. All hidden, so each library
# carries its own copy and exports none of them.
#
# lse.S is used from a patched copy: it names the helpers __aarch64_* in assembly, which on Mach-O
# is the C symbol _aarch64_* (C names get a leading underscore there), while clang's calls to the C
# function __aarch64_* reference ___aarch64_*.
bt=$WORK/builtins
rm -rf "$bt"
mkdir -p "$bt/obj"
sed 's/^#define NAME(BASE) GLUE4(__aarch64_, BASE, SIZE, SUFF)$/#if defined(__APPLE__)\n#define NAME(BASE) GLUE4(___aarch64_, BASE, SIZE, SUFF)\n#else\n#define NAME(BASE) GLUE4(__aarch64_, BASE, SIZE, SUFF)\n#endif/' \
	"$builtins_src/aarch64/lse.S" > "$bt/lse.S"
grep -q '___aarch64_' "$bt/lse.S" || { echo "lse.S: symbol name patch did not apply" >&2; exit 1; }
cflags="-target arm64-apple-macosx13.0 -isysroot $sdk -Wno-incompatible-sysroot -Wno-macro-redefined"
for op in cas swp ldadd ldclr ldeor ldset; do
	for size in 1 2 4 8 16; do
		[ "$op" = cas ] || [ "$size" != 16 ] || continue
		for model in 1 2 3 4 5; do
			# shellcheck disable=SC2086
			clang $cflags -I"$builtins_src" -DVISIBILITY_HIDDEN -DL_$op -DSIZE=$size -DMODEL=$model \
				-c "$bt/lse.S" -o "$bt/obj/$op${size}_$model.o"
		done
	done
done
# shellcheck disable=SC2086
clang $cflags -mcpu=apple-a7 -O2 -fvisibility=hidden -c "$here/outline-atomics-init.c" -o "$bt/obj/init.o"
# shellcheck disable=SC2086
clang $cflags -mcpu=apple-a7 -moutline-atomics -O2 -fvisibility=hidden \
	-c "$builtins_src/os_version_check.c" -o "$bt/obj/os_version_check.o"
(cd "$bt/obj" && find . -name '*.o' | LC_ALL=C sort | xargs llvm-ar rcs "$bt/libdarling_rt_builtins.a")

export SWIFT_TOOLCHAIN DARLING_RT_SDK="$sdk" DARLING_RT_BUILTINS="$bt/libdarling_rt_builtins.a"
install=$WORK/install
rm -rf "$install"
common="-G Ninja --toolchain $here/macos-arm64.cmake -DCMAKE_POLICY_DEFAULT_CMP0195=NEW
	-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=YES -DCMAKE_INSTALL_PREFIX=$install/usr
	-DCMAKE_INSTALL_NAME_DIR=/usr/lib/swift -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON"

# Core: libswiftCore, libswift_Concurrency, libswiftSwiftOnoneSupport, libswiftRemoteMirror.
# Upstream's Apple settings (Runtimes/Core/cmake/caches/Vendors/Apple/apple-common.cmake) except
# two. Stdlib tracing is off: upstream's option text says it requires os_log(3) and os_signpost(3),
# and whether Darling's os_signpost works was not checked. Strict availability is off: upstream's
# option text says it breaks things when the host OS is older than the runtime's @available
# annotations.
rm -rf "$WORK/build-core"
# shellcheck disable=SC2086
cmake -S "$swift_src/Runtimes/Core" -B "$WORK/build-core" $common \
	-C "$swift_src/Runtimes/Core/cmake/caches/Vendors/Apple/apple-common.cmake" \
	-DSwiftCore_ARCH_SUBDIR=arm64 -DSwiftCore_PLATFORM_SUBDIR=macosx -DSwiftCore_INSTALL_NESTED_SUBDIR=OFF \
	-DSwiftCore_ENABLE_CONCURRENCY=ON -DSwiftCore_ENABLE_REMOTE_MIRROR=ON -DSwiftCore_ENABLE_BACKTRACING=ON \
	-DSwiftCore_ENABLE_STDLIB_TRACING=OFF -DSwiftCore_ENABLE_STRICT_AVAILABILITY=OFF \
	-DSwiftCore_OPTIMIZATION_REMARKS=OFF \
	-Ddispatch_IMPLIB="$sdk/usr/lib/system/libdispatch.dylib" -Ddispatch_INCLUDE_DIR="$sdk/usr/include" \
	> "$WORK/core-configure.log"
ninja -C "$WORK/build-core" -j "$JOBS"
cmake --install "$WORK/build-core" > /dev/null

# Overlay: libswift_Builtin_float (the C++ interop overlays are not built).
rm -rf "$WORK/build-overlay"
# shellcheck disable=SC2086
cmake -S "$swift_src/Runtimes/Overlay" -B "$WORK/build-overlay" $common \
	-C "$swift_src/Runtimes/Overlay/cmake/caches/Vendors/Apple/apple-common.cmake" \
	-DSwiftOverlay_ARCH_SUBDIR=arm64 -DSwiftOverlay_PLATFORM_SUBDIR=macosx -DSwiftOverlay_INSTALL_NESTED_SUBDIR=OFF \
	-DSwiftOverlay_ENABLE_CXX_INTEROP=OFF -DSwiftCore_DIR="$install/usr/lib/cmake/SwiftCore" \
	> "$WORK/overlay-configure.log"
ninja -C "$WORK/build-overlay" -j "$JOBS"
cmake --install "$WORK/build-overlay" > /dev/null

# The Darwin overlay, which the Supplemental libraries import (Synchronization also links it): from
# ../overlays/Darwin, against the stdlib just built, arm64 only. Its module goes next to the
# stdlib's, where the Supplemental builds look for modules. It is used here only to compile and
# link the libraries below; the libswiftDarwin.dylib the repository ships is ../overlays/build.sh's.
# Darling's SDK module maps need clang's builtin headers inside the system modules (an SDK older
# than macOS 14 gets that from swiftc automatically).
modflags="-Xcc -Xclang -Xcc -fbuiltin-headers-in-system-modules -Xcc -Wno-macro-redefined"
# shellcheck disable=SC2086
"$SWIFT_TOOLCHAIN/bin/swiftc" -emit-library -emit-module "$repo"/overlays/Darwin/*.swift \
	-target arm64-apple-macosx13.0 -sdk "$sdk" -I "$install/usr/lib/swift" -I "$install/usr/lib/swift/shims" \
	-module-cache-path "$WORK/module-cache" -swift-version 5 -module-name Darwin -module-link-name swiftDarwin \
	-enable-library-evolution -parse-as-library -O -Xcc -mcpu=apple-a7 -Xcc -moutline-atomics \
	-Xcc -fmodule-map-file="$repo/overlays/shims/overlay-shims.modulemap" $modflags \
	-emit-module-path "$install/usr/lib/swift/Darwin.swiftmodule" \
	-use-ld="$(command -v ld64.lld)" -L "$install/usr/lib/swift" -L "$install/usr/lib/swift/macosx/arm64" \
	-Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 15.2 -Xlinker "$DARLING_RT_BUILTINS" \
	-Xlinker -install_name -Xlinker /usr/lib/swift/libswiftDarwin.dylib \
	-o "$sdk/usr/lib/swift/libswiftDarwin.dylib"

# Supplemental: each library is a CMake project of its own (the umbrella project's
# ExternalProject does not pass the toolchain file on).
supplemental="StringProcessing Synchronization Volatile Observation Distributed Differentiation"
for p in $supplemental; do
	rm -rf "$WORK/build-$p"
	# shellcheck disable=SC2086
	cmake -S "$swift_src/Runtimes/Supplemental/$p" -B "$WORK/build-$p" $common \
		-DSwiftCore_DIR="$install/usr/lib/cmake/SwiftCore" -DSwiftOverlay_DIR="$install/usr/lib/cmake/SwiftOverlay" \
		-DswiftDarwin_LIBRARY="$sdk/usr/lib/swift/libswiftDarwin.dylib" \
		-DCMAKE_SHARED_LINKER_FLAGS="-L$sdk/usr/lib/swift" > "$WORK/$p-configure.log"
	ninja -C "$WORK/build-$p" -j "$JOBS"
	cmake --install "$WORK/build-$p" > /dev/null
done

# A Swift resource directory (macosx/, shims/, clang/) for ../overlays/build.sh (SWIFT_RESOURCE_DIR; it then
# also needs SWIFT_EXTRA_FLAGS="-I $WORK/resource/shims" plus $modflags).
res=$WORK/resource
rm -rf "$res"
mkdir -p "$res/macosx"
for m in "$install"/usr/lib/swift/*.swiftmodule "$install"/usr/lib/swift/macosx/*.swiftmodule \
	"$install"/usr/lib/swift/*.dylib "$install"/usr/lib/swift/macosx/arm64/*.dylib \
	"$sdk/usr/lib/swift/libswiftDarwin.dylib"; do
	[ -e "$m" ] && ln -s "$m" "$res/macosx/"
done
ln -s "$install/usr/lib/swift/shims" "$res/shims"
ln -s "$SWIFT_TOOLCHAIN/lib/swift/clang" "$res/clang"

# Every arm64 runtime library the repository ships, as built above, collected into $WORK/arm64.
# libswiftCompatibilitySpan.dylib is a symlink to libswiftCore.dylib in the repository.
libs="libswiftCore libswift_Concurrency libswiftSwiftOnoneSupport libswiftRemoteMirror libswift_Builtin_float
	libswift_StringProcessing libswift_RegexParser libswiftRegexBuilder libswiftSynchronization libswift_Volatile
	libswiftObservation libswiftDistributed libswift_Differentiation"
rm -rf "$WORK/arm64"
mkdir -p "$WORK/arm64"
for lib in $libs; do
	new=$install/usr/lib/swift/$lib.dylib
	[ -f "$new" ] || new=$install/usr/lib/swift/macosx/arm64/$lib.dylib
	[ -f "$new" ] || { echo "$lib.dylib was not built" >&2; exit 1; }
	cp "$new" "$WORK/arm64/$lib.dylib"
done

# The check that matters, on the libraries just built: no instruction an ARMv8.0 core lacks
# outside the outline atomics helpers.
python3 "$here/scan-armv8.py" $(for lib in $libs; do echo "$WORK/arm64/$lib.dylib"; done)

# Merge each with the x86_64 slice already in the repository (not rebuilt here).
# MERGE_X86_64=0 stops after the check, leaving the arm64 libraries in $WORK/arm64.
[ "${MERGE_X86_64:-1}" != 0 ] || exit 0
for lib in $libs; do
	llvm-lipo -thin x86_64 "$repo/$lib.dylib" -output "$WORK/$lib.x86_64"
	llvm-lipo -create "$WORK/$lib.x86_64" "$WORK/arm64/$lib.dylib" -output "$repo/$lib.dylib"
	rm "$WORK/$lib.x86_64"
	echo "updated $lib.dylib: $(llvm-lipo -archs "$repo/$lib.dylib")"
done
