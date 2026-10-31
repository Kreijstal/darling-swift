# Toolchain for runtime/build.sh: Swift's runtime libraries for arm64 macOS,
# cross-compiled on Linux, for an ARMv8.0 baseline with outline atomics.
#
# The swift.org pkg's arm64 slices target Apple M1 and contain ARMv8.1 LSE
# atomics (cas, casp, ldadd...) and ARMv8.3 RCpc loads (ldapr) inline; an
# ARMv8.0 core (Cortex-A72, Exynos M3) dies on them with SIGILL. Here every
# compiler gets -mcpu=apple-a7 (ARMv8.0) and -moutline-atomics: atomics call
# compiler-rt's __aarch64_* helpers, which use LSE when the CPU has it
# (outline-atomics-init.c) and exclusive loops otherwise. swiftc takes the
# same flags through -Xcc: its code generator uses the Clang importer's
# target CPU and features.
#
# Environment (set by build.sh): SWIFT_TOOLCHAIN (usr/ of a Swift 6.3.3
# toolchain), DARLING_RT_SDK (a sysroot: SDK headers + Darling's usr/lib),
# DARLING_RT_BUILTINS (libdarling_rt_builtins.a: the outline atomics
# helpers and __isPlatformVersionAtLeast, which Apple links into each library
# from libclang_rt.osx.a).
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0 CACHE STRING "")
set(CMAKE_OSX_SYSROOT "$ENV{DARLING_RT_SDK}" CACHE PATH "")

set(CMAKE_C_COMPILER clang CACHE FILEPATH "")
set(CMAKE_CXX_COMPILER clang++ CACHE FILEPATH "")
set(CMAKE_Swift_COMPILER "$ENV{SWIFT_TOOLCHAIN}/bin/swiftc" CACHE FILEPATH "")
foreach(lang C CXX ASM Swift)
	set(CMAKE_${lang}_COMPILER_TARGET "arm64-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}" CACHE STRING "")
endforeach()
set(CMAKE_Swift_COMPILER_WORKS YES)
set(CMAKE_C_COMPILER_WORKS YES)
set(CMAKE_CXX_COMPILER_WORKS YES)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(DARLING_RT_CPU_FLAGS "-mcpu=apple-a7 -moutline-atomics")
find_program(DARLING_RT_LINKER ld64.lld REQUIRED)
# Link options live in the per-language flags, which CMake passes to both
# compiling and linking: CMAKE_SHARED_LINKER_FLAGS reaches clang and swiftc
# alike, and they spell linker options differently. compiler-rt builtins
# (DARLING_RT_BUILTINS) go into every library, hidden, as Apple's clang does.
set(DARLING_RT_C_LINK "-fuse-ld=${DARLING_RT_LINKER} -Wl,-platform_version,macos,${CMAKE_OSX_DEPLOYMENT_TARGET},15.2 $ENV{DARLING_RT_BUILTINS} -Wno-unused-command-line-argument")
set(CMAKE_C_FLAGS_INIT "-fblocks ${DARLING_RT_CPU_FLAGS} -Wno-incompatible-sysroot -Wno-macro-redefined ${DARLING_RT_C_LINK}")
set(CMAKE_CXX_FLAGS_INIT "-fblocks ${DARLING_RT_CPU_FLAGS} -Wno-incompatible-sysroot -Wno-macro-redefined ${DARLING_RT_C_LINK}")
set(CMAKE_ASM_FLAGS_INIT "${DARLING_RT_CPU_FLAGS}")
set(CMAKE_Swift_FLAGS_INIT "-Xcc -mcpu=apple-a7 -Xcc -moutline-atomics -Xcc -Xclang -Xcc -fbuiltin-headers-in-system-modules -use-ld=${DARLING_RT_LINKER} -Xlinker -platform_version -Xlinker macos -Xlinker ${CMAKE_OSX_DEPLOYMENT_TARGET} -Xlinker 15.2 -Xlinker $ENV{DARLING_RT_BUILTINS}")
find_program(CMAKE_AR llvm-ar REQUIRED)
find_program(CMAKE_RANLIB llvm-ranlib REQUIRED)
