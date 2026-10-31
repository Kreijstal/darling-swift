#!/bin/sh
# Rebuild the arm64 slices of the Swift runtime libraries from the Swift 6.3.3 sources, for an
# ARMv8.0 baseline with outline atomics, and merge them with the x86_64 slices already in the
# repository (unchanged swift.org builds).
#
# Why: the arm64 slices in swift-6.3.3-RELEASE-osx.pkg target Apple M1 and contain ARMv8.1 LSE
# atomics (cas, casp, ldadd, swp...) and ARMv8.3 RCpc loads (ldapr) inline: 722 such instructions
# in libswiftCore alone. An ARMv8.0 core (Cortex-A72 in the Pi 4, Exynos M3 in phones) raises
# SIGILL on the first one, the first time any Swift program allocates metadata. Here every
# compiler gets -mcpu=apple-a7 -moutline-atomics (macos-arm64.cmake): atomics become calls to
# compiler-rt's __aarch64_* helpers, linked into each library, which use LSE when
# sysctl hw.optional.armv8_1_atomics says the CPU has it and exclusive loops otherwise.
#
# Required environment:
#   SWIFT_TOOLCHAIN   usr/ of the Swift 6.3.3 toolchain (the Linux release works)
#   DARLING_ROOT      an installed Darling root (libexec/darling): libSystem, libobjc, libc++ and
#                     libdispatch are linked from its usr/lib
#   DARLING_SDK       Darling's MacOSX.sdk (Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
#                     in the darling tree): the headers, frameworks and module maps
#   CXX_HEADERS       a libc++ header directory (usr/include/c++ of an Apple SDK, e.g. an
#                     iPhoneOS16.5.sdk); Darling's SDK has none. Headers only.
# Optional:
#   WORK              build directory (default ./build next to this script)
#   SWIFT_SRC, STRING_PROCESSING_SRC, LLVM_SRC
#                     existing checkouts of the pinned commits below, for an offline build.
#                     Nothing verifies them, so point them at those commits. SWIFT_SRC is
#                     written to (Runtimes/Resync.cmake copies stdlib sources into it).
#   JOBS              ninja -j
#
# Output: the merged libraries are copied over the ones in the repository; the builtins archive
# (WORK/builtins/libdarling_rt_builtins.a) and resource directory (WORK/resource) are what
# ../overlays/build.sh takes as DARLING_RT_BUILTINS and SWIFT_RESOURCE_DIR.
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
cat > "$sdk/SDKSettings.json" <<'EOF'
{"CanonicalName":"macosx15.2","DisplayName":"macOS 15.2","Version":"15.2","MaximumDeploymentTarget":"15.2.99","IsBaseSDK":"YES","DefaultDeploymentTarget":"15.2","SupportedTargets":{"macosx":{"Archs":["arm64","x86_64"],"LLVMTargetTripleVendor":"apple","LLVMTargetTripleSys":"macosx","DefaultDeploymentTarget":"15.2","MinimumDeploymentTarget":"10.13","MaximumDeploymentTarget":"15.2.99","PlatformFamilyName":"macOS"}}}
EOF

# compiler-rt builtins, which Apple's clang links into every binary from libclang_rt.osx.a and
# Darling links without: the outline atomics helpers (lse.S, built once per operation, size and
# memory order, as compiler-rt's CMake does), their flag's initialiser (outline-atomics-init.c,
# written for Darling) and __isPlatformVersionAtLeast & co. (os_version_check.c). All hidden.
#
# lse.S is used from a patched copy: compiler-rt names the helpers __aarch64_* in assembly, which
# on Mach-O is the C symbol _aarch64_*, while clang calls ___aarch64_* (C __aarch64_*). Upstream
# never builds them for Darwin, where outline atomics are not the default.
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
common="-G Ninja --toolchain $here/macos-arm64.cmake -DCMAKE_POLICY_DEFAULT_CMP0195=NEW
	-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=YES -DCMAKE_INSTALL_PREFIX=$install/usr
	-DCMAKE_INSTALL_NAME_DIR=/usr/lib/swift -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON"

# Core: libswiftCore, libswift_Concurrency, libswiftSwiftOnoneSupport, libswiftRemoteMirror.
# Apple's settings (apple-common.cmake) except: crash reporter and os_signpost tracing off (Darling
# has neither), strict availability off, runtime function counters off (Apple's shipping build
# exports none). The exported symbol sets then match the pkg's (see README.md).
rm -rf "$WORK/build-core"
# shellcheck disable=SC2086
cmake -S "$swift_src/Runtimes/Core" -B "$WORK/build-core" $common \
	-C "$swift_src/Runtimes/Core/cmake/caches/Vendors/Apple/apple-common.cmake" \
	-DSwiftCore_ARCH_SUBDIR=arm64 -DSwiftCore_PLATFORM_SUBDIR=macosx -DSwiftCore_INSTALL_NESTED_SUBDIR=OFF \
	-DSwiftCore_ENABLE_CONCURRENCY=ON -DSwiftCore_ENABLE_REMOTE_MIRROR=ON -DSwiftCore_ENABLE_BACKTRACING=ON \
	-DSwiftCore_ENABLE_RUNTIME_FUNCTION_COUNTERS=OFF -DSwiftCore_ENABLE_CRASH_REPORTER_CLIENT=OFF \
	-DSwiftCore_ENABLE_STDLIB_TRACING=OFF -DSwiftCore_ENABLE_STRICT_AVAILABILITY=OFF \
	-DSwiftCore_OPTIMIZATION_REMARKS=OFF \
	-Ddispatch_IMPLIB="$sdk/usr/lib/system/libdispatch.dylib" -Ddispatch_INCLUDE_DIR="$sdk/usr/include" \
	> "$WORK/core-configure.log"
ninja -C "$WORK/build-core" -j "$JOBS"
cmake --install "$WORK/build-core" > /dev/null

# Overlay: libswift_Builtin_float (the C++ interop overlays are not shipped here).
rm -rf "$WORK/build-overlay"
# shellcheck disable=SC2086
cmake -S "$swift_src/Runtimes/Overlay" -B "$WORK/build-overlay" $common \
	-C "$swift_src/Runtimes/Overlay/cmake/caches/Vendors/Apple/apple-common.cmake" \
	-DSwiftOverlay_ARCH_SUBDIR=arm64 -DSwiftOverlay_PLATFORM_SUBDIR=macosx -DSwiftOverlay_INSTALL_NESTED_SUBDIR=OFF \
	-DSwiftOverlay_ENABLE_CXX_INTEROP=OFF -DSwiftCore_DIR="$install/usr/lib/cmake/SwiftCore" \
	> "$WORK/overlay-configure.log"
ninja -C "$WORK/build-overlay" -j "$JOBS"
cmake --install "$WORK/build-overlay" > /dev/null

# The Darwin overlay's module, which Synchronization imports: from ../overlays/Darwin, as for the
# shipped libswiftDarwin, against the stdlib just built. Only the module is used; the library
# Synchronization links is the repository's libswiftDarwin.dylib. Darling's SDK module maps need
# clang's builtin headers inside the system modules (an SDK older than macOS 14 gets that from
# swiftc automatically).
modflags="-Xcc -Xclang -Xcc -fbuiltin-headers-in-system-modules -Xcc -Wno-macro-redefined"
# shellcheck disable=SC2086
"$SWIFT_TOOLCHAIN/bin/swiftc" -emit-module "$repo"/overlays/Darwin/*.swift \
	-target arm64-apple-macosx13.0 -sdk "$sdk" -I "$install/usr/lib/swift" -I "$install/usr/lib/swift/shims" \
	-module-cache-path "$WORK/module-cache" -swift-version 5 -module-name Darwin -module-link-name swiftDarwin \
	-enable-library-evolution -parse-as-library -O \
	-Xcc -fmodule-map-file="$repo/overlays/shims/overlay-shims.modulemap" $modflags \
	-emit-module-path "$sdk/usr/lib/swift/Darwin.swiftmodule"
ln -s "$repo/libswiftDarwin.dylib" "$sdk/usr/lib/swift/libswiftDarwin.dylib"

# Supplemental: each library is a CMake project of its own (the umbrella project's
# ExternalProject does not pass the toolchain file on). Observation, Distributed,
# _Differentiation and Runtime are not built: they need os_unfair_lock and tgmath from the
# Darwin Clang module, which Darling's SDK module maps do not provide, and their pkg slices
# contain no ARMv8.1+ instructions (README.md).
for p in StringProcessing Synchronization Volatile; do
	rm -rf "$WORK/build-$p"
	# shellcheck disable=SC2086
	cmake -S "$swift_src/Runtimes/Supplemental/$p" -B "$WORK/build-$p" $common \
		-DSwiftCore_DIR="$install/usr/lib/cmake/SwiftCore" -DSwiftOverlay_DIR="$install/usr/lib/cmake/SwiftOverlay" \
		-DswiftDarwin_LIBRARY="$sdk/usr/lib/swift/libswiftDarwin.dylib" \
		-DCMAKE_SHARED_LINKER_FLAGS="-L$sdk/usr/lib/swift" > "$WORK/$p-configure.log"
	ninja -C "$WORK/build-$p" -j "$JOBS"
	cmake --install "$WORK/build-$p" > /dev/null
done

# A resource directory in the pkg's layout, for ../overlays/build.sh (SWIFT_RESOURCE_DIR; it then
# also needs SWIFT_EXTRA_FLAGS="-I $WORK/resource/shims" plus $modflags).
res=$WORK/resource
rm -rf "$res"
mkdir -p "$res/macosx"
for m in "$install"/usr/lib/swift/*.swiftmodule "$install"/usr/lib/swift/macosx/*.swiftmodule \
	"$install"/usr/lib/swift/*.dylib "$install"/usr/lib/swift/macosx/arm64/*.dylib \
	"$sdk/usr/lib/swift/Darwin.swiftmodule" "$sdk/usr/lib/swift/libswiftDarwin.dylib"; do
	[ -e "$m" ] && ln -s "$m" "$res/macosx/"
done
ln -s "$install/usr/lib/swift/shims" "$res/shims"
ln -s "$SWIFT_TOOLCHAIN/lib/swift/clang" "$res/clang"

# Merge with the repository's x86_64 slices.
libs="libswiftCore libswift_Concurrency libswiftSwiftOnoneSupport libswiftRemoteMirror libswift_Builtin_float
	libswift_StringProcessing libswift_RegexParser libswiftRegexBuilder libswiftSynchronization libswift_Volatile"
for lib in $libs; do
	new=$install/usr/lib/swift/$lib.dylib
	[ -f "$new" ] || new=$install/usr/lib/swift/macosx/arm64/$lib.dylib
	llvm-lipo -thin x86_64 "$repo/$lib.dylib" -output "$WORK/$lib.x86_64"
	llvm-lipo -create "$WORK/$lib.x86_64" "$new" -output "$repo/$lib.dylib"
	rm "$WORK/$lib.x86_64"
	echo "updated $lib.dylib: $(llvm-lipo -archs "$repo/$lib.dylib")"
done

# The check that matters: no instruction an ARMv8.0 core lacks outside the helpers.
python3 "$here/scan-armv8.py" $(for lib in $libs; do echo "$repo/$lib.dylib"; done)
