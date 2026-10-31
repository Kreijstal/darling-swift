#!/usr/bin/env python3
# scan-armv8.py FILE...: count the instructions an ARMv8.0 core lacks (LSE atomics, RCpc
# loads/stores, FJCVTZS) in each file's arm64 slice, outside compiler-rt's outline atomics
# helpers (___aarch64_*), which use LSE only when the CPU has it. Exits 1 if any are found.
import re, subprocess, sys, tempfile, os
BAD = re.compile(r'^(casp?(a|al|l)?[bh]?|ld(add|clr|eor|set|smax|smin|umax|umin)(a|al|l)?[bh]?|'
                 r'st(add|clr|eor|set|smax|smin|umax|umin)l?[bh]?|swp(a|al|l)?[bh]?|ldapu?r[bh]?|ldapurs[bhw]|stlur[bh]?|fjcvtzs)$')
total = 0
for path in sys.argv[1:]:
    tmp = None
    archs = subprocess.run(["llvm-lipo", "-archs", path], capture_output=True, text=True).stdout.split()
    if "arm64" not in archs:
        print("%-60s no arm64" % os.path.basename(path)); continue
    target = path
    if len(archs) > 1:
        tmp = tempfile.NamedTemporaryFile(delete=False); tmp.close()
        subprocess.run(["llvm-lipo", "-thin", "arm64", path, "-output", tmp.name], check=True)
        target = tmp.name
    dis = subprocess.run(["llvm-objdump", "-d", "--macho", "--no-show-raw-insn", "--mattr=+v9.4a,+lse,+rcpc,+rcpc3,+jsconv",
                          target], capture_output=True, text=True).stdout
    func = ""; bad = {}; helpers = 0
    for line in dis.splitlines():
        if line.endswith(":") and not line.startswith(" "):
            func = line[:-1]; continue
        m = re.match(r'\s*[0-9a-f]+:\s+(\S+)', line)
        if not m: continue
        mn = m.group(1)
        if BAD.match(mn):
            if func.startswith("___aarch64_"):
                helpers += 1
            else:
                bad.setdefault(mn, []).append(func)
    n = sum(len(v) for v in bad.values()); total += n
    print("%-60s %5d inline  (%d in helpers)%s" % (os.path.basename(path), n, helpers,
          "  " + ", ".join("%s:%d" % (k, len(v)) for k, v in sorted(bad.items())) if n else ""))
    if tmp: os.unlink(tmp.name)
print("TOTAL inline:", total)
sys.exit(1 if total else 0)
