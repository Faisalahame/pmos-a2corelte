#!/usr/bin/env python3
"""
Speed (branch display-6.19): make the kernel compile use ccache, so a re-run only recompiles what changed.

Why: the first full kernel build takes about 55 minutes on the 4-core GitHub runner, and every re-run (for example after a
failure in the root filesystem step, which happened in the run of 00:23) paid the full 55 minutes again.
pmbootstrap already installs ccache, but its ccache symlinks only wrap gcc. This kernel is built with LLVM=1 (clang), so
nothing was cached. This script edits scripts/build-pmos.sh in the CI checkout (the file in git is not changed):
  1. the kernel APKBUILD build() uses CC="ccache clang" HOSTCC="ccache clang"
  2. after the kernel build the size of pmbootstrap's ccache folders is logged (work/ccache-size.log)
The workflow keeps the ccache folders between runs with actions/cache (restore before, save after, also after a failure).
Run apply-display-backport.py first.
"""
import sys

P = "scripts/build-pmos.sh"
s = open(P).read()
if "pmos-a2corelte ccache" in s:
    print("ccache patch already applied")
    sys.exit(0)


def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, "anchor not found exactly once (%d): %r" % (n, old[:80])
    s = s.replace(old, new)


rep(
    """pmbootstrap -y checksum linux-postmarketos-exynos7870
""",
    r"""# pmos-a2corelte ccache: build() of the kernel package compiles with "ccache clang" (pmbootstrap's ccache symlinks only wrap gcc)
python3 - "$KDIR/APKBUILD" <<'PYEOF2'
import sys
p = sys.argv[1]
t = open(p).read()
def rep(old, new):
    global t
    assert t.count(old) == 1, "APKBUILD build() anchor missing or not unique: " + old[:60]
    t = t.replace(old, new)
rep('unset LDFLAGS', 'unset LDFLAGS\n\texport CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime\n\texport CCACHE_COMPILERCHECK="string:$(clang --version | head -n 1)"')
rep('LLVM=1 HOSTLDFLAGS="-fuse-ld=lld"', 'LLVM=1 CC="ccache clang" HOSTCC="ccache clang" HOSTLDFLAGS="-fuse-ld=lld"')
open(p, 'w').write(t)
print("kernel APKBUILD build(): ccache clang")
PYEOF2
grep -n 'ccache' "$KDIR/APKBUILD"
pmbootstrap -y checksum linux-postmarketos-exynos7870
""",
)

rep(
    """pmbootstrap -y build --arch aarch64 --force linux-postmarketos-exynos7870
""",
    """pmbootstrap -y build --arch aarch64 --force linux-postmarketos-exynos7870
{ du -sh "$WORK"/cache_ccache_* 2>&1; } | tee work/ccache-size.log || true
""",
)

open(P, "w").write(s)
print("scripts/build-pmos.sh patched for ccache")
