#!/usr/bin/env python3
"""
display-6.19 branch: hook scripts/greeter-fix.sh into scripts/fixup-rootfs.sh (in the CI checkout only; the file in git
is not changed). See scripts/greeter-fix.sh for what it does (greeter waits for the display, touch diagnostics use the
right i2c bus on 6.19).
"""
import sys

P = "scripts/fixup-rootfs.sh"
s = open(P).read()
if "greeter-fix.sh" in s:
    print("greeter fix already hooked in")
    sys.exit(0)
s = s.rstrip("\n") + "\n\n# ---- display-6.19: greeter waits for the display, touch diagnostics use the right bus ----\nbash \"$(dirname \"$0\")/greeter-fix.sh\" \"$IMG\"\n"
open(P, "w").write(s)
print("scripts/fixup-rootfs.sh: greeter-fix.sh hooked in")
