# arm64 runtime slices for ARMv8.0

`build.sh` rebuilds the arm64 slices of the Swift runtime libraries from the Swift 6.3.3 sources and
merges them with the x86_64 slices from swift.org, which stay unchanged.

## Why

The arm64 slices in `swift-6.3.3-RELEASE-osx.pkg` target Apple M1. They contain ARMv8.1 LSE atomics
(`cas`, `casp`, `ldadd`, `swp`, ...) and ARMv8.3 RCpc loads (`ldapr`, `ldapur`, `stlur`) inline. An
ARMv8.0 core raises SIGILL on the first one. That covers the Pi 4's Cortex-A72 and the Exynos 9810's
cores in the Galaxy Note10 Lite. A Swift program first hits one in
`swift::MetadataAllocator::Allocate` (`casp`), the first time it instantiates metadata.

`scan-armv8.py` counted these instructions in the pkg slices, outside any helper function. These are
counts from the files listed, measured on 2026-10-30:

| Library | Inline ARMv8.1+ instructions (pkg) | After `build.sh` |
|---|---|---|
| `libswiftCore` | 722 | 0 (18 inside the outline helpers) |
| `libswift_Concurrency` | 75 | 0 (14 in helpers) |
| `libswiftRemoteMirror` | 18 | 0 (2 in helpers) |
| `libswiftSynchronization` | 3 | 0 (100 in helpers) |
| `libswift_StringProcessing` | 1 | 0 (1 in helper) |
| `libswiftSwiftOnoneSupport`, `libswift_RegexParser`, `libswiftRegexBuilder`, `libswift_Volatile`, `libswift_Builtin_float` | 0 | 0 (rebuilt anyway, from the same sources) |
| `libswiftObservation`, `libswiftDistributed`, `libswift_Differentiation`, `libswiftRuntime` | 0 | not rebuilt (see below) |

## How

`macos-arm64.cmake` gives every compiler `-mcpu=apple-a7`, which is ARMv8.0, and `-moutline-atomics`.
`swiftc` takes the same two flags through `-Xcc`, because its code generator uses the Clang
importer's target CPU and features. Each atomic then calls one of compiler-rt's `__aarch64_*`
helpers. The helper runs a single LSE instruction when `__aarch64_have_lse_atomics` is set, and an
exclusive-load/store loop otherwise. Both paths are correct on any CPU. The flag only picks the
faster one.

The helpers are linked into every library, hidden, together with their initialiser and
`__isPlatformVersionAtLeast`. Apple's clang does the same from `libclang_rt.osx.a`, which is how the
pkg's libswiftCore got its copy. The archive (`libdarling_rt_builtins.a`) holds three things:

- **`lse.S`** from compiler-rt, assembled once per operation, size and memory order, as
  compiler-rt's CMake does. It is assembled from a patched copy: upstream names the helpers in a
  way that is wrong for Mach-O, since it never builds them for Darwin (see the comment in
  `build.sh`).
- **`outline-atomics-init.c`**, written for Darling. A constructor sets the flag from
  `sysctlbyname("hw.optional.armv8_1_atomics")`, as compiler-rt does on Darwin since LLVM 19.
  Darling answers that sysctl, and the other `hw.optional.*` CPU feature keys, from the Linux host's
  `AT_HWCAP`/`AT_HWCAP2`; the code is in darling-xnu `.../helper/misc/sysctl_hw.c`.
- **`os_version_check.c`** from compiler-rt.

Sources, pinned by commit (each comment in `build.sh` gives the `git ls-remote` that checks it):

- `swiftlang/swift` `064859e4` (tag `swift-6.3.3-RELEASE`), built with the standalone runtime build
  in `Runtimes/` after its `Resync.cmake`.
- `swiftlang/swift-experimental-string-processing` `efe89868` (tag `swift-6.3.3-RELEASE`).
- `llvm/llvm-project` `2078da43` (tag `llvmorg-21.1.8`). Only `lse.S`, `assembly.h` and
  `os_version_check.c` are used.

The compiler-rt files are Apache-2.0 WITH LLVM-exception. `outline-atomics-init.c`, `macos-arm64.cmake`, `build.sh` and `scan-armv8.py` were written for Darling.

Settings are Apple's (`apple-common.cmake`), with four changes:

- No CrashReporter client.
- No os_signpost tracing.
- No strict availability.
- No runtime function counters. Apple's shipping libswiftCore exports none.

The exported symbol sets, compared with `llvm-nm --defined-only --extern-only | sort -u` against
the pkg slices:

- **`libswiftCore`:** 14,884 exports in the pkg. None is missing; one is extra,
  `_swift_getFatalErrorMessageBuffer`.
- **`libswift_StringProcessing`:** 373 in the pkg. None is missing; four `__swift_string_processing_get*`
  data accessors are extra.
- **All the others:** identical sets.

Control: comparing the new libswiftCore against the pkg's `libswift_Concurrency` reports all 1,320
of its exports missing.

The libraries stay macOS binaries (platform macos, minimum 13.0, as the pkg's). They link Darling's
`libc++`, which also adds a direct `libc++abi.dylib` dependency.

## Not rebuilt

- **`libswiftObservation`, `libswiftDistributed`, `libswift_Differentiation`, `libswiftRuntime`:**
  these need `os_unfair_lock` and `tgmath` from the `Darwin` Clang module, and `libswiftRuntime`
  also needs the C++ interop overlay. Darling's SDK module maps do not provide the first two. Their
  pkg slices contain none of the instructions above, so they run on ARMv8.0 as they are.
- **The SDK overlays** are `../overlays/build.sh`'s, which now uses the same CPU flags and links
  `libdarling_rt_builtins.a`. So far only `Combine.framework` has been rebuilt with them: it had 1
  `ldadd` and now has none, with an identical export set (1,680 symbols).
- **`libswiftFoundation`** still has 86 inline `ldadd`. Rebuilding it needs the prepared SDK that
  `overlays/build.sh` documents (Clang module maps for ObjectiveC, Dispatch, Foundation and the
  rest). Darling's in-tree SDK fails at `ObjectiveC` and then at `libkern` header redefinitions.
  Until it is rebuilt, a Swift program that uses the Foundation overlay can still trap on an ARMv8.0
  CPU.
- **CryptoKit, GroupActivities and the other overlays' arm64 slices** contain none of these
  instructions.

## Building

```sh
SWIFT_TOOLCHAIN=<swift-6.3.3-RELEASE-ubuntu24.04>/usr \
DARLING_ROOT=<installed darling root, libexec/darling> \
DARLING_SDK=<darling>/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
CXX_HEADERS=<an Apple SDK>/usr/include/c++ \
sh runtime/build.sh
```

`CXX_HEADERS` is needed only because Darling's SDK ships no libc++ headers. Only headers are taken
from it.

The script overwrites the ten merged libraries in this directory and ends with `scan-armv8.py` over
them, which exits 1 if any such instruction is left. `WORK` (default `runtime/build`) keeps:

- `builtins/libdarling_rt_builtins.a` and `resource/`. `../overlays/build.sh` takes them as
  `DARLING_RT_BUILTINS` and `SWIFT_RESOURCE_DIR`. With this resource directory it also needs
  `SWIFT_EXTRA_FLAGS="-I <WORK>/resource/shims -Xcc -Xclang -Xcc -fbuiltin-headers-in-system-modules"`.
- `sdk/`, the sysroot the build assembles.

Rebuilt binaries follow `../CLAUDE.md`: rebase rather than merge, and compare symbol sets, not bytes.
