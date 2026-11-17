# Darling Swift

Attention: This repository uses Git LFS!

Files found here come from official Swift releases from Swift.org. They are downloaded and extracted using the `build.sh` script before committing.

The runtime libraries (`libswiftCore`, `libswift_Concurrency`, `libswift_StringProcessing`, `libswiftObservation`, ...) come from the release in `version.txt` and are universal (arm64 and x86_64) binaries. Most of their arm64 slices are rebuilt from source for ARMv8.0 CPUs by `runtime/build.sh` (see `runtime/README.md`).

Swift.org toolchains no longer include the Darwin SDK overlays (`libswiftAppKit`, `libswiftFoundation`, `libswiftObjectiveC`, `libswiftDispatch`, ...). `libswiftDarwin`, `libswiftObjectiveC`, `libswiftCoreFoundation`, `libswiftCoreGraphics`, `libswiftDispatch`, `libswiftFoundation`, `libswiftos` and `libswiftXPC` are built from the sources in `overlays/` by CMake (see `overlays/README.md`), for x86_64 or arm64 like the rest of Darling, and are skipped when the build finds no Swift toolchain. The other overlays still in this repository come from Swift 5.2.2 and are x86_64-only.

`stdlib-modules/` holds the textual module interfaces (`.swiftinterface`, x86_64 and arm64) of the runtime's Swift modules, taken from the same package. The Swift compiler needs them to build code for macOS against this runtime, because the Linux toolchains have no macOS standard library module. The Swift SDK overlays in this repository are built from source against them by CMake when a Swift toolchain is available.

## Helper dylibs built by CMake

A few small libraries are built from the sources in this directory (`CMakeLists.txt`) instead of being copied from a release. The ones that re-export `libswiftDarwin` are built only together with the overlays, i.e. when a Swift toolchain was found:

- `libswift_errno`, `libswift_DarwinFoundation1/2/3`, `libswift_math`, `libswift_signal`, `libswift_stdio`, `libswift_time`, `libswiftsys_time` and `libswiftunistd` contain no code. Recent macOS SDKs split the Darwin overlay across these libraries and binaries bind Darwin symbols to them by library ordinal. Here the whole overlay lives in `libswiftDarwin.dylib`, so each of these libraries only re-exports it.
- `libswiftWebKit` only defines the `__swift_FORCE_LOAD_$_swiftWebKit` marker, so that binaries that link the WebKit overlay load. It exports nothing else.

## License and provenance

- **Runtime libraries:** the x86_64 slices, and the arm64 slices of `libswiftObservation`, `libswiftDistributed`, `libswift_Differentiation` and `libswiftRuntime`, are unmodified binaries from `usr/lib/swift/macosx` in `swift-6.3.3-RELEASE-osx.pkg` from download.swift.org (SHA-256 `ee82e57774d6650f94aa06302435d6f44a055b9411698db8ecb85d9a3bcc91d0`). `libswiftCompatibilitySpan.dylib` is a symlink to `libswiftCore.dylib`, as in the pkg. `runtime/build.sh` also builds arm64 slices of `libswiftObservation`, `libswiftDistributed` and `libswift_Differentiation`, but until a run merges them, the committed arm64 slices of those three are still the pkg's.
- **Runtime libraries, arm64 slices of `libswiftCore`, `libswift_Concurrency`, `libswiftSwiftOnoneSupport`, `libswiftRemoteMirror`, `libswift_Builtin_float`, `libswift_StringProcessing`, `libswift_RegexParser`, `libswiftRegexBuilder`, `libswiftSynchronization` and `libswift_Volatile`:** built by `runtime/build.sh` from the swift-6.3.3-RELEASE sources (pinned commits there) for an ARMv8.0 baseline with outline atomics. Unmodified Swift programs died with SIGILL on a Cortex-A72 under Darling and run with these; see `runtime/README.md`. Each carries hidden copies of compiler-rt's outline atomics helpers, `os_version_check.c` and `runtime/outline-atomics-init.c`.
- **Module interfaces:** the `*-apple-macos.swiftinterface` files in `usr/lib/swift/macosx/<Module>.swiftmodule` of the same package, unmodified (`Swift`, `_Concurrency`, `_StringProcessing`, `_RegexParser`, `RegexBuilder`, `Observation`, `Synchronization`, `Distributed`, `_Builtin_float`, `_Volatile`, `Runtime`, `_Differentiation`, `SwiftOnoneSupport`).
- **Overlays built from `overlays/`:** `libswiftDarwin`, `libswiftObjectiveC`, `libswiftCoreFoundation`, `libswiftCoreGraphics`, `libswiftDispatch`, `libswiftFoundation`, `libswiftos`, `libswiftXPC` and the SDK overlays in `overlays/sdk-frameworks.cmake` (IOKit, CoreAudio, AppKit, Compression, CoreText, UniformTypeIdentifiers, Network) are compiled by CMake when a Swift toolchain is found and are not stored in this repository. `Combine.framework` is built from OpenCombine the same way.
- **Prebuilt arm64 overlays:** the overlays that `CMakeLists.txt` does not build (`libswiftDeveloperToolsSupport`, `libswiftQuartzCore`, `libswiftSceneKit`, `libswiftCoreMedia`, the force-load overlays and `CryptoKit.framework`) are built from `overlays/` by `overlays/build.sh` and committed as arm64 slices.
- **`swift_compat.S`:** written for Darling, not taken from a Swift release. `CMakeLists.txt` builds it into `libswiftCoreCompat.dylib`.
- **Other overlays:** unmodified x86_64 binaries from the Swift 5.2.2 macOS pkg.

Swift is Copyright Apple Inc. and the Swift project authors, and is licensed under the Apache License v2.0 with Runtime Library Exception. `LICENSE.txt` is the copy shipped in the pkg (`usr/share/swift/LICENSE.txt`).
