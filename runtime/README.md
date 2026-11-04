# Swift runtime for ARMv8.0

`build.sh` rebuilds the arm64 slices of this repository's Swift runtime libraries from Swift's open
source so that they run on every ARMv8.0-A CPU, the Raspberry Pi 4's Cortex-A72 included, and then
merges each with the x86_64 slice already in the repository.

## What was observed

Unmodified Swift programs died with `SIGILL` on a Cortex-A72 under Darling. With the libraries
`build.sh` produces they run.

## Why a rebuild fixes it

When clang is given no `-mcpu`, it picks a CPU from the target triple. You can see which one with
`-###`. The Swift 6.3.3 toolchain's clang picks `apple-m1` for `arm64-apple-macosx13.0` and
`apple-a7` for `arm64-apple-ios16.0`:

```sh
clang -target arm64-apple-macosx13.0 -### -c x.c 2>&1 | grep -o '"-target-cpu" "[^"]*"'
```

`--print-enabled-extensions` lists what each CPU enables:

```sh
clang --target=arm64-apple-macosx13.0 -mcpu=apple-m1 --print-enabled-extensions
clang --target=arm64-apple-macosx13.0 -mcpu=apple-a7 --print-enabled-extensions
clang --target=aarch64-linux-gnu -mcpu=cortex-a72 --print-enabled-extensions
```

`apple-m1` enables, among others, FEAT_LSE ("Armv8.1-A Large System Extension (LSE) atomic
instructions") and FEAT_LRCPC and FEAT_LRCPC2 (RCpc load-acquire instructions). `apple-a7` and
`cortex-a72` enable neither: both are Armv8.0-A. Code compiled for `apple-m1` may therefore contain
instructions that a Cortex-A72 does not implement, and executing an unimplemented instruction
raises `SIGILL`.

You can see the difference on a one-line C function that does `atomic_fetch_add`. Compiled
with `-target arm64-apple-macosx13.0 -O2` alone, `scan-armv8.py` finds one `ldaddal` in it.
Compiled with `-mcpu=apple-a7 -moutline-atomics` added, it finds none, because the function now
calls a helper. That is also a quick check that the scan can fail.

Swift code is affected in the same way. swiftc's code generator takes its target CPU and features
from its Clang importer (`swift/lib/IRGen/IRGen.cpp`), so `-Xcc -mcpu=...` reaches Swift code as
well as C and C++.

## What `build.sh` does

1. It fetches Swift (`swift-6.3.3-RELEASE`), swift-experimental-string-processing
   (`swift-6.3.3-RELEASE`) and three files of LLVM's compiler-rt (`llvmorg-21.1.8`), each pinned
   by commit. It then runs Swift's `Runtimes/Resync.cmake`, which lays out the sources for the
   standalone runtime build.
2. It assembles a sysroot from Darling's SDK, libc++ headers and the libraries of an installed
   Darling. One change to Darling's module map is needed. Observation imports `Darwin.os.lock`
   (`Runtimes/Supplemental/Observation/Sources/Observation/Locking.swift`) and _Differentiation
   imports `Darwin.C.tgmath` (`Runtimes/Supplemental/Differentiation/TgmathDerivatives.swift.gyb`).
   Darling's Darwin module is a single umbrella with neither submodule, so the sysroot gets a copy
   of its module map with those two added.
3. It compiles everything, whether C, C++, assembly or Swift, for `arm64-apple-macosx13.0` with
   `-mcpu=apple-a7 -moutline-atomics` (`macos-arm64.cmake`):
   - `-mcpu=apple-a7` limits code generation to Armv8.0-A.
   - `-moutline-atomics` ("Generate local calls to out-of-line atomic operations", `clang
     --help`) turns each atomic operation into a call to a helper,
     `__aarch64_<op><size>_<order>`, from compiler-rt's `lib/builtins/aarch64/lse.S`. Each helper
     tests `__aarch64_have_lse_atomics`. When the flag is set, the helper runs the single LSE
     instruction. Otherwise it runs a load-exclusive/store-exclusive loop, which every Armv8.0
     core has.
4. The sysroot provides neither the helpers nor clang's `__isPlatformVersionAtLeast`, so the
   script builds them into `libdarling_rt_builtins.a` and links that archive, hidden, into every
   library. The archive holds:
   - `lse.S`, assembled once per operation, size and memory order;
   - `outline-atomics-init.c`, written for Darling, which sets the flag from
     `sysctlbyname("hw.optional.armv8_1_atomics")`;
   - compiler-rt's `os_version_check.c`, which provides `__isPlatformVersionAtLeast`, the function
     clang calls for `@available` checks.

   If the sysctl fails or returns 0, the flag stays false and the helpers use the exclusive
   loops. That is correct on any core and only slower where LSE exists.
5. It builds the libraries with Swift's own CMake projects and upstream's Apple settings
   (`Runtimes/*/cmake/caches/Vendors/Apple/apple-common.cmake`), with two exceptions in Core:
   - Stdlib tracing is off. Upstream's option text says it requires `os_log(3)` and
     `os_signpost(3)`, and nobody has checked whether Darling's `os_signpost` works.
   - Strict availability is off. Upstream's option text says it breaks things when the host OS is
     older than the runtime's `@available` annotations.

   The libraries it builds:

   | Project | Libraries |
   |---|---|
   | `Runtimes/Core` | `libswiftCore`, `libswift_Concurrency`, `libswiftSwiftOnoneSupport`, `libswiftRemoteMirror` |
   | `Runtimes/Overlay` | `libswift_Builtin_float` |
   | `Runtimes/Supplemental` | `libswift_StringProcessing`, `libswift_RegexParser`, `libswiftRegexBuilder`, `libswiftSynchronization`, `libswift_Volatile`, `libswiftObservation`, `libswiftDistributed`, `libswift_Differentiation` |

   `libswiftCompatibilitySpan.dylib` is a symlink to `libswiftCore.dylib` in this repository. The
   Supplemental libraries compile against an arm64 Darwin overlay that the script builds from
   `../overlays/Darwin` for that purpose only. The `libswiftDarwin.dylib` this repository ships
   comes from `../overlays/build.sh`.
6. It copies the libraries to `$WORK/arm64` and runs `scan-armv8.py` over those copies. The scan
   fails if it finds an LSE, RCpc or FJCVTZS instruction anywhere outside the `___aarch64_*`
   helpers. The scan reads only this build's output.
7. It merges each library with the x86_64 slice already in the repository. The x86_64 slices are
   not rebuilt. With `MERGE_X86_64=0` the script stops after the scan.

## Not rebuilt yet: `libswiftRuntime`

`Runtimes/Supplemental/Runtime` is compiled with `-cxx-interoperability-mode=default`, and its
CMake project requires `SwiftCxxOverlay`, which includes the `CxxStdlib` overlay. That overlay
imports libc++'s clang module `std`. Darling's libc++ (15) ships only `module.modulemap.in`. Even
with a module map generated from that file, the module fails against Darling's single-umbrella
Darwin module with `cyclic dependency in module 'std': std -> Darwin -> std`, because libc++'s C
wrapper headers (`math.h`, for example) include C++ headers and Darwin's umbrella includes those
wrappers. Making the wrappers textual does not break the cycle. Until that is solved, the arm64
slice of `libswiftRuntime.dylib` is not rebuilt by this script, and this README makes no claim
about it.

## Running it

```sh
SWIFT_TOOLCHAIN=.../swift-6.3.3-RELEASE-ubuntu24.04/usr \
DARLING_ROOT=~/.darling \
DARLING_SDK=<darling>/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
CXX_HEADERS=<a directory whose v1/ is <darling>/src/external/libcxx/include> \
WORK=/some/scratch/dir \
runtime/build.sh
```

`clang`, `ld64.lld`, `llvm-ar`, `llvm-lipo` and `llvm-objdump` come from `PATH`. `ld64.lld` must
be able to link for macOS, and the Swift Linux toolchain's cannot ("This version of lld does not
support linking for platform macOS"), so put a full LLVM ahead of it. On a distribution without
`libncurses.so.6` the toolchain's `swiftc` also needs one on `LD_LIBRARY_PATH`. `build.sh`'s header
lists the optional variables.

`../CLAUDE.md` asks for an exported-symbol-set comparison after every rebuild. Run it on the
`$WORK/arm64` libraries against an earlier `$WORK/arm64` from this script, and never against a
binary this script did not build.
