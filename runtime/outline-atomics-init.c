/*
 * Written for Darling.
 *
 * The flag compiler-rt's outline atomics helpers (aarch64/lse.S,
 * __aarch64_cas8_acq_rel and friends) test before every atomic operation:
 * true means the CPU has ARMv8.1 LSE atomics and the helper runs one LSE
 * instruction, false means it runs a load/store-exclusive loop, which every
 * ARMv8.0 core has. Both paths are correct; the flag only picks the faster.
 *
 * compiler-rt sets it from sysctlbyname("hw.optional.armv8_1_atomics") on
 * Darwin (cpu_model/aarch64/lse_atomics/apple.inc, LLVM 19 and later);
 * this is the same, so that each Swift runtime library built by
 * runtime/build.sh carries its own copy (hidden, like the helpers) and
 * needs nothing from libSystem but sysctlbyname. Darling answers the
 * sysctl from the Linux host's HWCAP_ATOMICS.
 *
 * Until the constructor runs the flag is false, which is safe.
 */

#include <stddef.h>
#include <sys/sysctl.h>

__attribute__((visibility("hidden"))) _Bool __aarch64_have_lse_atomics = 0;

__attribute__((constructor, visibility("hidden"))) void __darling_init_have_lse_atomics(void)
{
	int value = 0;
	size_t size = sizeof(value);
	if (sysctlbyname("hw.optional.armv8_1_atomics", &value, &size, NULL, 0) == 0)
		__aarch64_have_lse_atomics = value != 0;
}
