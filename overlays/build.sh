#!/bin/sh
# Build the arm64 slices of the Swift SDK overlays in this directory and merge them with the
# x86_64 slices already in the repository (Swift 5.2.2 builds from swift.org).
#
# Required environment:
#   SWIFT_TOOLCHAIN     usr/ directory of a Swift 6.3.3 toolchain (the Linux release works)
#   SWIFT_RESOURCE_DIR  usr/lib/swift from swift-6.3.3-RELEASE-osx.pkg (Swift/_Concurrency modules, shims, clang headers)
#   DARLING_SDK         Darling's MacOSX.sdk, including the Clang module maps and API notes for
#                       Darwin, ObjectiveC, Dispatch, os, CoreFoundation and the sys/cdefs.h default-platform fix
#   DARLING_LD          Darling's ld64 (build/src/external/cctools-port/cctools/ld64/src/aarch64-apple-darwin20-ld)
#   DARLING_LIBSYSTEM   Darling's built libSystem.B.dylib
#   DARLING_ROOT        installed Darling root (libexec/darling): libobjc and CoreFoundation are linked from it
#   DARLING_RT_BUILTINS libdarling_rt_builtins.a from ../runtime/build.sh: compiler-rt's outline
#                       atomics helpers (and __isPlatformVersionAtLeast), linked into every binary
# Optional:
#   LD_EXTRA_FLAGS      extra ld64 flags, e.g. the -dylib_file mappings Darling's own executables link with
#   SWIFT_EXTRA_FLAGS   extra swiftc -frontend flags, e.g. -I <resource dir>/shims when SWIFT_RESOURCE_DIR
#                       is ../runtime/build.sh's output rather than the pkg's usr/lib/swift
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
: "${SWIFT_TOOLCHAIN:?}" "${SWIFT_RESOURCE_DIR:?}" "${DARLING_SDK:?}" "${DARLING_LD:?}" "${DARLING_LIBSYSTEM:?}" "${DARLING_ROOT:?}" "${DARLING_RT_BUILTINS:?}"
# arm64 code is built for an ARMv8.0 baseline (apple-a7) with outline atomics, like the runtime
# libraries (see ../runtime/README.md): -target arm64-apple-macosx alone means Apple M1, whose LSE
# atomics and RCpc loads an ARMv8.0 core (Cortex-A72, Exynos M3) traps on. Atomics then call the
# __aarch64_* helpers in DARLING_RT_BUILTINS, which use LSE only where the CPU has it.
ARM64_SWIFT_CPU="-Xcc -mcpu=apple-a7 -Xcc -moutline-atomics ${SWIFT_EXTRA_FLAGS:-}"
ARM64_C_CPU="-mcpu=apple-a7 -moutline-atomics"
LD_EXTRA_FLAGS=${LD_EXTRA_FLAGS:-}
out="$here/build"
mkdir -p "$out/modules" "$out/obj"

# Write one source path per line, quoted, for swiftc's response file. Backslashes and quotes
# are escaped: LLVM's tokenizer would otherwise turn such a path into a different filename
# silently rather than failing.
write_source() {
	printf '"%s"\n' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" >> "$2"
}

# Collect every .swift under a directory into a response file, in a stable order.
collect_sources() {
	: > "$2"
	find "$1" -name '*.swift' | LC_ALL=C sort | while IFS= read -r f; do write_source "$f" "$2"; done
}

# build_module <Module> <sources...> [--sources-from <file of paths>]
#              [-- <extra swiftc -frontend flags>] [--link <extra ld inputs>]
# Source paths may contain spaces; flags and link inputs may not, since both are expanded as word
# lists on the command line.
build_module() {
	module=$1
	shift
	swift_flags=""
	link_inputs=""
	mode=src
	: > "$out/$module.sources"
	for arg in "$@"; do
		case "$arg" in
			--) mode=flags ;;
			--link) mode=link ;;
			--sources-from) mode=srcfile ;;
			*) case "$mode" in
				src) write_source "$arg" "$out/$module.sources" ;;
				srcfile) while IFS= read -r src_line; do
						[ -n "$src_line" ] || continue
						write_source "$src_line" "$out/$module.sources"
					done < "$arg" ;;
				flags) swift_flags="$swift_flags $arg" ;;
				link) link_inputs="$link_inputs $arg" ;;
			esac ;;
		esac
	done

	# Library evolution, like Apple's SDK overlays, so binaries built against the macOS SDK use the same access patterns.
	# shellcheck disable=SC2086
	"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c @"$out/$module.sources" \
		-target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" $ARM64_SWIFT_CPU \
		-module-cache-path "$out/module-cache" -swift-version 5 \
		-module-name "$module" -module-link-name "swift$module" -autolink-force-load \
		-enable-library-evolution -parse-as-library -O \
		-I "$out/modules" \
		-Xcc -fmodule-map-file="$here/shims/overlay-shims.modulemap" \
		-emit-module-path "$out/modules/$module.swiftmodule" \
		-o "$out/obj/$module.o" $swift_flags

	# shellcheck disable=SC2086
"$DARLING_LD" -dylib -arch arm64 "$DARLING_RT_BUILTINS" -platform_version macos 26.0 26.0 -syslibroot "$DARLING_SDK" -syslibroot "$DARLING_ROOT" \
		-install_name "/usr/lib/swift/libswift$module.dylib" \
		-compatibility_version 1.0.0 -current_version 1.0.0 \
		$LD_EXTRA_FLAGS \
		-L "$SWIFT_RESOURCE_DIR/macosx" -L "$out" \
		"$out/obj/$module.o" "$DARLING_LIBSYSTEM" "$DARLING_ROOT/usr/lib/libobjc.A.dylib" \
		-lswiftCore $link_inputs \
		-o "$out/libswift$module.dylib"
}

corefoundation="$DARLING_ROOT/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"

# merge_x86_64 MODULE...: join each arm64 slice built in "$out" with the x86_64 slice in the repository.
merge_x86_64() {
	for module in "$@"; do
		dylib="libswift$module.dylib"
		llvm-lipo -thin x86_64 "$repo/$dylib" -output "$out/$dylib.x86_64" 2>/dev/null || cp "$repo/$dylib" "$out/$dylib.x86_64"
		llvm-lipo -create "$out/$dylib.x86_64" "$out/$dylib" -output "$repo/$dylib"
		rm "$out/$dylib.x86_64"
		echo "updated $dylib: $(llvm-lipo -archs "$repo/$dylib")"
	done
}

# iOS SDK overlays whose x86_64 slices are Swift 5.2.2 builds with no arm64 slice, so dyld refused to
# load an arm64 app that links them. The frameworks behind them are stubs in Darling, so the 5.2.2
# sources cannot be built against Darling's SDK. Apps import only the force-load symbol from these,
# so each is ForceLoad/ForceLoad.swift built under its module name:
FORCE_LOAD_ONLY_OVERLAYS="AVFoundation Accelerate Compression CoreImage CoreLocation GLKit GameplayKit Intents MapKit Metal MetalKit ModelIO SpriteKit simd"
# and these two carry the API apps do import, clean-room (see README). Network, the third, imports
# Foundation and Dispatch, so it is built after them (build_network).
SDK_OVERLAYS="$FORCE_LOAD_ONLY_OVERLAYS CoreAudio CoreMedia"
build_sdk_overlays() {
	for module in $FORCE_LOAD_ONLY_OVERLAYS; do
		build_module "$module" "$here/ForceLoad/ForceLoad.swift"
	done
	build_module CoreAudio "$here/CoreAudio/CoreAudio.swift" -- -Xcc -fmodule-map-file="$here/CoreAudio/shims/module.modulemap" --link -lswiftDarwin
	build_module CoreMedia "$here/CoreMedia/CoreMedia.swift" -- -Xcc -fmodule-map-file="$here/CoreMedia/shims/module.modulemap"
}

# Network: clean-room, over BSD sockets and Dispatch, with TLS from libnetwork's libtls session
# (src/external/libnetwork/src/nw/darling_tls.m), so it links the libnetwork built with it.
# LIBNETWORK points at that build when DARLING_ROOT holds an older one.
build_network() {
	libnetwork=${LIBNETWORK:-$DARLING_ROOT/usr/lib/libnetwork.dylib}
	build_module Network "$here"/Network/*.swift -- -Xcc -fmodule-map-file="$here/Network/shims/module.modulemap" -Xcc -fmodule-map-file="$here/CoreGraphics/shims/module.modulemap" --link "$libnetwork" "$foundation" -lswiftFoundation -lswiftDispatch -lswiftObjectiveC -lswiftDarwin
	merge_x86_64 Network
}

build_module Darwin "$here"/Darwin/*.swift
# Focused mode for the SDK overlays below, which need only the Darwin overlay; run before the
# ObjectiveC overlay so an SDK whose ObjectiveC module cannot be built still builds them.
if [ "${DARLING_SWIFT_SDK_OVERLAYS_ONLY:-0}" = 1 ]; then
	build_sdk_overlays
	# shellcheck disable=SC2086
	merge_x86_64 $SDK_OVERLAYS
	exit 0
fi
build_module ObjectiveC "$here/ObjectiveC/ObjectiveC.swift" -- -disable-objc-attr-requires-foundation-module --link -lswiftDarwin
build_module CoreFoundation "$here"/CoreFoundation/*.swift --link "$corefoundation" -lswiftDarwin
# Combine: OpenCombine built as module `Combine`, so its mangled names match what apps import.
# Unlike the overlays above this is a framework binary, not a /usr/lib/swift dylib, and it has no
# x86_64 slice to merge with. See overlays/README.md.
#
# Built before Foundation, and its .swiftmodule goes into "$out/modules": the Foundation overlay
# imports Combine for NSObject.KeyValueObservingPublisher, so every client of Foundation has to be
# able to load Combine, as with Apple's SDK. Built before Dispatch, too: the Dispatch overlay makes
# DispatchQueue a Combine Scheduler. Combine itself is compiled without -I "$out/modules".
#
# OpenCombine is fetched rather than vendored, for the same reason swift-collections is above.
# The fork adds functional Merge and MergeMany publishers; the Darwin-specific adaptations
# remain in Combine/patches/, applied below.
#
# Pinned BY COMMIT on purpose: a branch reference would make this build non-reproducible.
# This commit is on cristim/OpenCombine's feature/darling-merge-publishers branch and is
# proposed upstream as OpenCombine PR #258.
# OPENCOMBINE_SRC can point at an already-fetched checkout, the way SWIFT_COLLECTIONS_SRC does
# above, so an offline build needs no network. Nothing verifies that checkout, so point it at the
# pinned commit.
OPENCOMBINE_URL=${OPENCOMBINE_URL:-https://github.com/cristim/OpenCombine.git}
OPENCOMBINE_COMMIT=${OPENCOMBINE_COMMIT:-10df981a64800643559490d72174f43438562e73}
opencombine_src=${OPENCOMBINE_SRC:-$out/OpenCombine}
if [ -z "${OPENCOMBINE_SRC:-}" ]; then
	if [ ! -d "$opencombine_src/.git" ]; then
		git clone --quiet --filter=blob:none "$OPENCOMBINE_URL" "$opencombine_src"
	fi
	git -C "$opencombine_src" fetch --quiet origin "$OPENCOMBINE_COMMIT" \
		|| git -C "$opencombine_src" fetch --quiet origin
	git -C "$opencombine_src" checkout --quiet --detach "$OPENCOMBINE_COMMIT"
fi

# Patch a copy, never the checkout: OPENCOMBINE_SRC may point at one this build does not own, and
# rebuilding from scratch each time is what makes the patches apply exactly once.
rm -rf "$out/combine-src"
cp -R "$opencombine_src/Sources/OpenCombine" "$out/combine-src"
for p in "$here"/Combine/patches/*.patch; do
	patch -p1 -s -d "$out/combine-src" < "$p"
done
# Darling's additions: the parts of Apple's Combine OpenCombine lacks (see Combine/Darling).
cp "$here"/Combine/Darling/*.swift "$out/combine-src/"

"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 $ARM64_C_CPU -isysroot "$DARLING_SDK" \
	-I "$opencombine_src/Sources/COpenCombineHelpers/include" -Wall -Wextra -O2 -fvisibility=hidden \
	-c "$here/Combine/helpers.c" -o "$out/obj/CombineHelpers.o"

# find order is filesystem order, so the source list goes through collect_sources' LC_ALL=C sort.
collect_sources "$out/combine-src" "$out/Combine.sources"
"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c @"$out/Combine.sources" \
	-target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" $ARM64_SWIFT_CPU \
	-module-cache-path "$out/module-cache" -swift-version 5 \
	-module-name Combine \
	-enable-library-evolution -parse-as-library -O \
	-Xcc -fmodule-map-file="$opencombine_src/Sources/COpenCombineHelpers/include/module.modulemap" \
	-emit-module-path "$out/modules/Combine.swiftmodule" \
	-o "$out/obj/Combine.o"

mkdir -p "$repo/Combine.framework/Versions/A"
# shellcheck disable=SC2086
"$DARLING_LD" -dylib -arch arm64 "$DARLING_RT_BUILTINS" -platform_version macos 26.0 26.0 -syslibroot "$DARLING_SDK" \
	-install_name "/System/Library/Frameworks/Combine.framework/Versions/A/Combine" \
	-compatibility_version 1.0.0 -current_version 1.0.0 \
	$LD_EXTRA_FLAGS \
	-L "$SWIFT_RESOURCE_DIR/macosx" \
	"$out/obj/Combine.o" "$out/obj/CombineHelpers.o" \
	"$DARLING_LIBSYSTEM" "$DARLING_ROOT/usr/lib/libobjc.A.dylib" \
	-lswiftCore \
	-o "$repo/Combine.framework/Versions/A/Combine"
echo "updated Combine.framework: $(llvm-lipo -archs "$repo/Combine.framework/Versions/A/Combine")"

"$SWIFT_TOOLCHAIN/bin/clang++" -target arm64-apple-macosx26.0 $ARM64_C_CPU -isysroot "$DARLING_SDK" -I "$here/Dispatch/include" \
	-std=c++17 -fobjc-arc -O2 -c "$here/Dispatch/Dispatch.mm" -o "$out/obj/Dispatch.mm.o"
"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 $ARM64_C_CPU -isysroot "$DARLING_SDK" -fobjc-arc -O2 \
	-c "$here/Dispatch/DarlingSerialExecutor.m" -o "$out/obj/DarlingSerialExecutor.m.o"
build_module Dispatch "$here"/Dispatch/*.swift --link "$out/obj/Dispatch.mm.o" "$out/obj/DarlingSerialExecutor.m.o" "$repo/Combine.framework/Versions/A/Combine" -lswiftObjectiveC -lswiftDarwin
build_module os "$here/os/os.swift" -- -Xcc -fmodule-map-file="$here/os/shims/module.modulemap" --link -lswiftDarwin -lswiftObjectiveC -lswiftDispatch
build_module XPC "$here/XPC/XPC.swift" -- -Xcc -fmodule-map-file="$here/XPC/shims/module.modulemap" --link -lswiftDarwin -lswiftObjectiveC -lswiftDispatch

# The AppKit, QuartzCore and CoreText overlays re-export their Clang module, but only where the SDK ships one:
# swift-darling's own SDK carries none of these frameworks, while an SDK built over Darling's in-tree headers
# does. Without the re-export the Swift module shadows the Clang module and hides every Objective-C
# type behind it; with it, against an SDK that has no such module, the import is a hard error.
clang_module_flag() {
	if [ -f "$DARLING_SDK/System/Library/Frameworks/$1.framework/Modules/module.modulemap" ]; then
		printf -- '-D DARLING_%s_CLANG_MODULE' "$2"
	fi
}

# The two overlays this repository added to the macOS Swift runtime, built together because the
# AppKit overlay imports DeveloperToolsSupport for NSImage.init(resource:). DeveloperToolsSupport
# is arm64-only: the repository carries no x86_64 slice to merge with (see the UniformTypeIdentifiers
# and CoreText comments below). Symbols that would normally link from the Foundation and CoreGraphics
# overlays resolve instead from the repository's own libswift*.dylib via -L "$repo", so this works
# as a focused rebuild outside the full pipeline.
build_appkit_overlays() {
	foundation="$DARLING_ROOT/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
	appkit="$DARLING_ROOT/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
	coregraphics="$DARLING_ROOT/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics"
	# CGFloat lives in the CoreFoundation overlay (as in current SDKs), but binaries built against
	# SDKs where it was CoreGraphics' bind its metadata and conformances to libswiftCoreGraphics
	# (Lottie does): re-export the CoreFoundation overlay so dyld finds them through this one.
	build_module CoreGraphics "$here"/CoreGraphics/*.swift -- -Xcc -fmodule-map-file="$here/CoreGraphics/shims/module.modulemap" --link "$coregraphics" "$corefoundation" -reexport_library "$out/libswiftCoreFoundation.dylib" -lswiftDarwin
	build_module DeveloperToolsSupport "$here/DeveloperToolsSupport/DeveloperToolsSupport.swift" --link "$foundation" -lswiftFoundation -lswiftObjectiveC -lswiftDarwin -L "$repo"
	cp "$out/libswiftDeveloperToolsSupport.dylib" "$repo/libswiftDeveloperToolsSupport.dylib"
	echo "updated libswiftDeveloperToolsSupport.dylib: $(llvm-lipo -archs "$repo/libswiftDeveloperToolsSupport.dylib")"
	build_module AppKit "$here/AppKit/AppKit.swift" -- $(clang_module_flag AppKit APPKIT) -Xcc -fmodule-map-file="$here/AppKit/shims/module.modulemap" -Xcc -fmodule-map-file="$here/CoreGraphics/shims/module.modulemap" --link "$appkit" "$foundation" -lswiftFoundation -lswiftCoreGraphics -lswiftCoreFoundation -lswiftObjectiveC -lswiftDarwin -lswiftDeveloperToolsSupport -L "$repo"
}

# Focused mode, mirroring DARLING_SWIFT_FOUNDATION_ONLY: build and publish just the overlays this
# change touches, skipping the Combine, Foundation and CryptoKit pipeline entirely.
if [ "${DARLING_SWIFT_APPKIT_ONLY:-0}" = 1 ]; then
	build_appkit_overlays
	llvm-lipo -thin x86_64 "$repo/libswiftAppKit.dylib" -output "$out/AppKit.x86_64" 2>/dev/null || cp "$repo/libswiftAppKit.dylib" "$out/AppKit.x86_64"
	llvm-lipo -create "$out/AppKit.x86_64" "$out/libswiftAppKit.dylib" -output "$repo/libswiftAppKit.dylib"
	rm -f "$out/AppKit.x86_64"
	echo "updated libswiftAppKit.dylib: $(llvm-lipo -archs "$repo/libswiftAppKit.dylib")"
	exit 0
fi



# AttributedString stores its text in swift-collections' BigString. Both modules are an
# implementation detail of the Foundation overlay: they are compiled without library evolution
# and their objects are linked straight into libswiftFoundation, the way Apple's Foundation
# links CollectionsInternal, rather than shipped as dylibs of their own.
build_object() {
	module=$1
	srcdir=$2
	collect_sources "$srcdir" "$out/$module.sources"
	"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c @"$out/$module.sources" \
		-target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" $ARM64_SWIFT_CPU \
		-module-cache-path "$out/module-cache" -swift-version 5 \
		-module-name "$module" -parse-as-library -O \
		-I "$out/modules" \
		-emit-module-path "$out/modules/$module.swiftmodule" \
		-o "$out/obj/$module.o"
}
# swift-collections is fetched rather than vendored: unlike overlays/Foundation/*, which is Apple
# overlay source adapted for Darling, these files are consumed exactly as upstream ships them.
#
# Pinned BY COMMIT on purpose: a branch or tag reference would make this build non-reproducible.
# c11818f3... is the commit tag 1.1.6 points at; check that with
#   git ls-remote https://github.com/apple/swift-collections.git refs/tags/1.1.6
# SWIFT_COLLECTIONS_SRC can point at an already-fetched checkout, the way SWIFT_PKG does for the
# toolchain in the top-level build.sh, so an offline build needs no network. Nothing verifies that
# checkout, so point it at the pinned commit.
SWIFT_COLLECTIONS_URL=${SWIFT_COLLECTIONS_URL:-https://github.com/apple/swift-collections.git}
SWIFT_COLLECTIONS_COMMIT=${SWIFT_COLLECTIONS_COMMIT:-c11818f3cae0780656baa430b49e7f163f08dffd}
collections_src=${SWIFT_COLLECTIONS_SRC:-$out/swift-collections}
if [ -z "${SWIFT_COLLECTIONS_SRC:-}" ]; then
	if [ ! -d "$collections_src/.git" ]; then
		git clone --quiet --filter=blob:none "$SWIFT_COLLECTIONS_URL" "$collections_src"
	fi
	git -C "$collections_src" fetch --quiet origin "$SWIFT_COLLECTIONS_COMMIT" \
		|| git -C "$collections_src" fetch --quiet origin
	git -C "$collections_src" checkout --quiet --detach "$SWIFT_COLLECTIONS_COMMIT"
fi
build_object InternalCollectionsUtilities "$collections_src/Sources/InternalCollectionsUtilities"
build_object _RopeModule "$collections_src/Sources/RopeModule"

# Keep the linked-in swift-collections symbols out of libswiftFoundation's export table, the way
# Apple hides CollectionsInternal. The patterns go in a file rather than on the command line
# because build_module re-splits its link inputs, where a bare '*' would be glob-expanded.
printf '_$s11_RopeModule*\n_$s28InternalCollectionsUtilities*\n' > "$out/unexported.txt"

# swift-cmark (swiftlang's cmark-gfm fork, BSD-2-Clause, see Foundation/LICENSE-swift-cmark.txt) is
# the CommonMark/GFM parser under AttributedString's Markdown initializers. Fetched and pinned like
# swift-collections, and linked into libswiftFoundation the same way: CMARK_GFM_STATIC_DEFINE plus
# -fvisibility=hidden make every cmark symbol private to the dylib, so none is exported.
# 924936d0... is tag swift-6.3.3-RELEASE; check that with
#   git ls-remote https://github.com/swiftlang/swift-cmark.git refs/tags/swift-6.3.3-RELEASE
# SWIFT_CMARK_SRC can point at an already-fetched checkout for an offline build. Nothing verifies
# that checkout, so point it at the pinned commit.
SWIFT_CMARK_URL=${SWIFT_CMARK_URL:-https://github.com/swiftlang/swift-cmark.git}
SWIFT_CMARK_COMMIT=${SWIFT_CMARK_COMMIT:-924936d0427cb25a61169739a7660230bffa6ea6}
cmark_src=${SWIFT_CMARK_SRC:-$out/swift-cmark}
if [ -z "${SWIFT_CMARK_SRC:-}" ]; then
	if [ ! -d "$cmark_src/.git" ]; then
		git clone --quiet --filter=blob:none "$SWIFT_CMARK_URL" "$cmark_src"
	fi
	git -C "$cmark_src" fetch --quiet origin "$SWIFT_CMARK_COMMIT" \
		|| git -C "$cmark_src" fetch --quiet origin
	git -C "$cmark_src" checkout --quiet --detach "$SWIFT_CMARK_COMMIT"
fi
# The same sources as the package's cmark-gfm and cmark-gfm-extensions targets, in LC_ALL=C order
# so the link order is stable.
mkdir -p "$out/obj/cmark"
: > "$out/cmark-objects.list"
find "$cmark_src/src" "$cmark_src/extensions" -maxdepth 1 -name '*.c' | LC_ALL=C sort | while IFS= read -r c; do
	obj="$out/obj/cmark/$(basename "$(dirname "$c")")-$(basename "$c" .c).o"
	"$SWIFT_TOOLCHAIN/bin/clang" -target arm64-apple-macosx26.0 $ARM64_C_CPU -isysroot "$DARLING_SDK" -O2 \
		-fvisibility=hidden -DCMARK_GFM_STATIC_DEFINE -DNDEBUG \
		-I "$cmark_src/src/include" -I "$cmark_src/extensions/include" -c "$c" -o "$obj"
	printf '%s\n' "$obj" >> "$out/cmark-objects.list"
done
cmark_flags="-Xcc -DCMARK_GFM_STATIC_DEFINE -Xcc -I$cmark_src/src/include -Xcc -fmodule-map-file=$cmark_src/src/include/module.modulemap -Xcc -fmodule-map-file=$cmark_src/extensions/include/module.modulemap"

# swift-foundation supplies AttributedString and the FormatStyle protocols. Fetched, not vendored,
# for the same reason as swift-collections: 34 of the 37 files are taken exactly as upstream ships
# them. The three that Darling has to change live in Foundation/ and are listed in
# DARLING-CHANGES.md; they are simply not taken from the checkout here.
#
# Pinned BY COMMIT on purpose: a branch reference would make this build non-reproducible.
# dbacc67779... is tag swift-6.3.3-RELEASE; check that with
#   git ls-remote https://github.com/swiftlang/swift-foundation.git refs/tags/swift-6.3.3-RELEASE
# SWIFT_FOUNDATION_SRC can point at an already-fetched checkout for an offline build. Nothing
# verifies that checkout, so point it at the pinned commit. It is never written to.
SWIFT_FOUNDATION_URL=${SWIFT_FOUNDATION_URL:-https://github.com/swiftlang/swift-foundation.git}
SWIFT_FOUNDATION_COMMIT=${SWIFT_FOUNDATION_COMMIT:-dbacc67779dc0a41ddc9493acbaa332d76c9fb03}
foundation_src=${SWIFT_FOUNDATION_SRC:-$out/swift-foundation}
if [ -z "${SWIFT_FOUNDATION_SRC:-}" ]; then
	if [ ! -d "$foundation_src/.git" ]; then
		git clone --quiet --filter=blob:none "$SWIFT_FOUNDATION_URL" "$foundation_src"
	fi
	git -C "$foundation_src" fetch --quiet origin "$SWIFT_FOUNDATION_COMMIT" \
		|| git -C "$foundation_src" fetch --quiet origin
	git -C "$foundation_src" checkout --quiet --detach "$SWIFT_FOUNDATION_COMMIT"
fi

: > "$out/foundation-upstream.list"
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	printf '%s\n' "$foundation_src/Sources/FoundationEssentials/$rel" >> "$out/foundation-upstream.list"
done <<'UPSTREAM_FILES'
AttributedString/AttributeContainer.swift
AttributedString/AttributedString+AttributeTransformation.swift
AttributedString/AttributedString+CharacterView.swift
AttributedString/AttributedString+Guts.swift
AttributedString/AttributedString+IndexTracking.swift
AttributedString/AttributedString+IndexValidity.swift
AttributedString/AttributedString+Runs+AttributeSlices.swift
AttributedString/AttributedString+Runs+Run.swift
AttributedString/AttributedString+Runs.swift
AttributedString/AttributedString+UTF16View.swift
AttributedString/AttributedString+UTF8View.swift
AttributedString/AttributedString+UnicodeScalarView.swift
AttributedString/AttributedString+_InternalRun.swift
AttributedString/AttributedString+_InternalRuns.swift
AttributedString/AttributedString+_InternalRunsSlice.swift
AttributedString/AttributedString.swift
AttributedString/AttributedStringAttributeConstrainingBehavior.swift
AttributedString/AttributedStringCodable.swift
AttributedString/AttributedSubstring.swift
AttributedString/Collection Stdlib Defaults.swift
AttributedString/DiscontiguousAttributedSubstring.swift
AttributedString/String.Index+ABI.swift
CodableWithConfiguration.swift
Formatting/BinaryInteger+NumericStringRepresentation.swift
Formatting/Date+ISO8601FormatStyle.swift
Formatting/DiscreteFormatStyle.swift
Formatting/FormatParsingUtilities.swift
Formatting/FormatStyle.swift
Formatting/FormatterCache.swift
Formatting/ParseStrategy.swift
Formatting/ParseableFormatStyle.swift
JSON/BufferView.swift
JSON/BufferViewIndex.swift
JSON/BufferViewIterator.swift
Locale/Locale+Language.swift
LockedState.swift
OutputBuffer.swift
String/BidirectionalCollection.swift
String/StringBlocks.swift
UPSTREAM_FILES

# ICU-backed format styles, unmodified, over Darling's ICU 66 as `_FoundationICU` (shims/FoundationICU.h);
# Foundation/FormattingSupport.swift supplies the Locale and Calendar internals (see DARLING-CHANGES.md).
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	printf '%s\n' "$foundation_src/Sources/FoundationInternationalization/$rel" >> "$out/foundation-upstream.list"
done <<'UPSTREAM_INTL_FILES'
BinaryFloatingPoint.swift
Date+ICU.swift
Duration+Utils.swift
Formatting/ByteCountFormatStyle.swift
Formatting/Date/Date+AnchoredRelativeFormatStyle.swift
Formatting/Date/Date+RelativeFormatStyle.swift
Formatting/Date/Date+VerbatimFormatStyle.swift
Formatting/Date/DateFieldSymbol.swift
Formatting/Date/DateFormatString.swift
Formatting/Date/DateFormatStyle.swift
Formatting/Date/DateParseStrategy.swift
Formatting/Date/ICUDateFormatter.swift
Formatting/Date/ICURelativeDateFormatter.swift
Formatting/Duration+Formatting.swift
Formatting/Duration+TimeFormatStyle.swift
Formatting/Number/BinaryFloatingPoint+FormatStyle.swift
Formatting/Number/BinaryInteger+FormatStyle.swift
Formatting/Number/FloatingPointFormatStyle.swift
Formatting/Number/FloatingPointParseStrategy.swift
Formatting/Number/ICULegacyNumberFormatter.swift
Formatting/Number/ICUNumberFormatter.swift
Formatting/Number/IntegerFormatStyle.swift
Formatting/Number/IntegerParseStrategy.swift
Formatting/Number/NumberAttributedFormat.swift
Formatting/Number/NumberFormatStyleConfiguration.swift
ICU/ICU+FieldPositer.swift
ICU/ICU+Foundation.swift
RangeExpression.swift
TimeInterval+Utils.swift
UPSTREAM_INTL_FILES

# Intentionally partial: String, Array, Dictionary and Set bridging, plus AttributedString and
# the FormatStyle protocols (see README).
foundation="$DARLING_ROOT/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
# shellcheck disable=SC2086
build_module Foundation "$here"/Foundation/*.swift --sources-from "$out/foundation-upstream.list" -- -package-name swift-foundation $cmark_flags --link -unexported_symbols_list "$out/unexported.txt" "$out/obj/_RopeModule.o" "$out/obj/InternalCollectionsUtilities.o" -filelist "$out/cmark-objects.list" "$foundation" "$corefoundation" "$DARLING_ROOT/usr/lib/libicucore.A.dylib" "$repo/Combine.framework/Versions/A/Combine" -lswiftDarwin -lswiftObjectiveC -lswiftCoreFoundation -lswiftDispatch

# Build just Foundation for focused overlay changes without rebuilding or replacing
# the other shipped Swift dylibs.
if [ "${DARLING_SWIFT_FOUNDATION_ONLY:-0}" = 1 ]; then
	echo "built Foundation overlay at $out/libswiftFoundation.dylib"
	exit 0
fi

# Minimal clean-room AppKit overlay (see README).
build_appkit_overlays

# Minimal clean-room QuartzCore overlay (see README).
build_module QuartzCore "$here/QuartzCore/QuartzCore.swift" -- $(clang_module_flag QuartzCore QUARTZCORE) -Xcc -fmodule-map-file="$here/QuartzCore/shims/module.modulemap"

# Intentionally partial: the vector and matrix conversions and SCNBoundingVolume only (see README).
scenekit="$DARLING_ROOT/System/Library/Frameworks/SceneKit.framework/Versions/A/SceneKit"
build_module SceneKit "$here/SceneKit/SceneKit.swift" -- -Xcc -fmodule-map-file="$here/SceneKit/shims/module.modulemap" -Xcc -fmodule-map-file="$here/CoreGraphics/shims/module.modulemap" --link "$scenekit" "$foundation" "$corefoundation" -lswiftFoundation -lswiftCoreGraphics -lswiftCoreFoundation -lswiftObjectiveC -lswiftDarwin

build_sdk_overlays
build_network

# UniformTypeIdentifiers is arm64-only: the x86_64 slice built from ../libswiftUniformTypeIdentifiers.S held
# placeholder values, so there is nothing to merge with.
uti="$DARLING_ROOT/System/Library/Frameworks/UniformTypeIdentifiers.framework/Versions/A/UniformTypeIdentifiers"
build_module UniformTypeIdentifiers "$here/UniformTypeIdentifiers/UniformTypeIdentifiers.swift" -- $(clang_module_flag UniformTypeIdentifiers UNIFORMTYPEIDENTIFIERS) -Xcc -fmodule-map-file="$here/UniformTypeIdentifiers/shims/module.modulemap" --link "$uti" "$foundation" "$corefoundation" -lswiftFoundation -lswiftCoreFoundation -lswiftObjectiveC -lswiftDarwin
cp "$out/libswiftUniformTypeIdentifiers.dylib" "$repo/libswiftUniformTypeIdentifiers.dylib"
echo "updated libswiftUniformTypeIdentifiers.dylib: $(llvm-lipo -archs "$repo/libswiftUniformTypeIdentifiers.dylib")"

# Intentionally partial: AttributedString.AdaptiveImageGlyph only (see README). arm64-only, like UniformTypeIdentifiers:
# there is no x86_64 slice to merge with.
coretext="$DARLING_ROOT/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText"
build_module CoreText "$here/CoreText/CoreText.swift" -- $(clang_module_flag CoreText CORETEXT) -package-name DarlingCoreText -Xcc -fmodule-map-file="$here/CoreText/shims/module.modulemap" -Xcc -fmodule-map-file="$here/UniformTypeIdentifiers/shims/module.modulemap" --link "$coretext" "$foundation" -lswiftUniformTypeIdentifiers -lswiftFoundation -lswiftCoreFoundation -lswiftObjectiveC -lswiftDarwin
cp "$out/libswiftCoreText.dylib" "$repo/libswiftCoreText.dylib"
echo "updated libswiftCoreText.dylib: $(llvm-lipo -archs "$repo/libswiftCoreText.dylib")"

# GroupActivities: Apple's is closed source and pure Swift, with no open-source twin, so the source
# here declares only the public API shape, which is what makes the mangled names match what apps
# bind. Deliberately inert: SharePlay needs a coordination daemon Darling does not have. See
# overlays/README.md.
#
# Links against Combine.framework above for the 9 Combine symbols the @Published properties pull in,
# so Combine must be built first and stays a non-weak runtime dependency of the installed framework.
collect_sources "$here/GroupActivities/Sources" "$out/GroupActivities.sources"
mkdir -p "$out/modules-groupactivities"
"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c @"$out/GroupActivities.sources" \
	-target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" $ARM64_SWIFT_CPU \
	-module-cache-path "$out/module-cache" -swift-version 5 \
	-module-name GroupActivities \
	-enable-library-evolution -parse-as-library -O \
	-I "$out/modules" \
	-emit-module-path "$out/modules-groupactivities/GroupActivities.swiftmodule" \
	-o "$out/obj/GroupActivities.o"

mkdir -p "$repo/GroupActivities.framework/Versions/A"
# shellcheck disable=SC2086
"$DARLING_LD" -dylib -arch arm64 "$DARLING_RT_BUILTINS" -platform_version macos 26.0 26.0 -syslibroot "$DARLING_SDK" \
	-install_name "/System/Library/Frameworks/GroupActivities.framework/Versions/A/GroupActivities" \
	-compatibility_version 1.0.0 -current_version 1.0.0 \
	$LD_EXTRA_FLAGS \
	-L "$SWIFT_RESOURCE_DIR/macosx" \
	"$out/obj/GroupActivities.o" \
	"$repo/Combine.framework/Versions/A/Combine" \
	"$DARLING_LIBSYSTEM" "$DARLING_ROOT/usr/lib/libobjc.A.dylib" \
	-lswiftCore \
	-o "$repo/GroupActivities.framework/Versions/A/GroupActivities"
echo "updated GroupActivities.framework: $(llvm-lipo -archs "$repo/GroupActivities.framework/Versions/A/GroupActivities")"

# CryptoKit: Apple's is closed source and pure Swift. swift-crypto deliberately mirrors its public
# API, so building it as module `CryptoKit` makes the mangled names match what apps import. Darling
# cannot link BoringSSL into this framework, so the fork below supplies a pure-Swift SHA-256 and
# neutralises the `canImport(CryptoKit)` guards that would otherwise collapse the package into an
# empty module re-exporting itself. See overlays/README.md and the fork's DARLING-CHANGES.md.
#
# Pinned BY COMMIT on purpose: a branch reference would make this build non-reproducible.
CRYPTOKIT_FORK_URL=${CRYPTOKIT_FORK_URL:-https://github.com/cristim/swift-crypto.git}
CRYPTOKIT_FORK_COMMIT=${CRYPTOKIT_FORK_COMMIT:-c4105ade5fbe6866375ec65146cac733d53a1146}
crypto_src="$out/swift-crypto"
if [ ! -d "$crypto_src/.git" ]; then
	git clone --quiet --filter=blob:none "$CRYPTOKIT_FORK_URL" "$crypto_src"
fi
git -C "$crypto_src" fetch --quiet origin "$CRYPTOKIT_FORK_COMMIT" \
	|| git -C "$crypto_src" fetch --quiet origin
git -C "$crypto_src" checkout --quiet --detach "$CRYPTOKIT_FORK_COMMIT"

# SHA-256 and HMAC-SHA-256 only: that is what the corpus binds. See overlays/README.md.
cryptokit_sources="
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
"
cryptokit_files=""
for f in $cryptokit_sources; do
	cryptokit_files="$cryptokit_files $crypto_src/$f"
done
# These three live in a directory whose name contains spaces, so they are passed separately.
mac_dir="$crypto_src/Sources/Crypto/Message Authentication Codes"

mkdir -p "$out/modules-cryptokit"
# shellcheck disable=SC2086
"$SWIFT_TOOLCHAIN/bin/swiftc" -frontend -c $cryptokit_files \
	"$mac_dir/HMAC/HMAC.swift" "$mac_dir/MessageAuthenticationCode.swift" "$mac_dir/MACFunctions.swift" \
	-target arm64-apple-macosx26.0 -sdk "$DARLING_SDK" -resource-dir "$SWIFT_RESOURCE_DIR" $ARM64_SWIFT_CPU \
	-module-cache-path "$out/module-cache" -swift-version 5 \
	-module-name CryptoKit \
	-D DARLING_CRYPTOKIT_MODULE -enable-experimental-feature Lifetimes \
	-enable-library-evolution -parse-as-library -O \
	-I "$out/modules" \
	-Xcc -fmodule-map-file="$here/shims/overlay-shims.modulemap" \
	-emit-module-path "$out/modules-cryptokit/CryptoKit.swiftmodule" \
	-o "$out/obj/CryptoKit.o"

mkdir -p "$repo/CryptoKit.framework/Versions/A"
# shellcheck disable=SC2086
"$DARLING_LD" -dylib -arch arm64 "$DARLING_RT_BUILTINS" -platform_version macos 26.0 26.0 -syslibroot "$DARLING_SDK" \
	-install_name "/System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit" \
	-compatibility_version 1.0.0 -current_version 1.0.0 \
	$LD_EXTRA_FLAGS \
	-L "$SWIFT_RESOURCE_DIR/macosx" -L "$out" \
	"$out/obj/CryptoKit.o" \
	"$DARLING_LIBSYSTEM" "$DARLING_ROOT/usr/lib/libobjc.A.dylib" \
	-lswiftCore -lswiftFoundation -lswiftCoreFoundation -lswiftDarwin -lswiftObjectiveC \
	-o "$repo/CryptoKit.framework/Versions/A/CryptoKit"
echo "updated CryptoKit.framework: $(llvm-lipo -archs "$repo/CryptoKit.framework/Versions/A/CryptoKit")"

# shellcheck disable=SC2086
merge_x86_64 Darwin ObjectiveC CoreFoundation Dispatch os XPC Foundation CoreGraphics AppKit QuartzCore SceneKit $SDK_OVERLAYS
