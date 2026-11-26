#!/usr/bin/env python3
"""
Diagnostic build (display-6.19 only): force the RMI4 touch driver to be BUILT IN (=y).

Why: the running kernel (6.19.6 #100) has CONFIG_RMI4_CORE=m and CONFIG_RMI4_I2C=m although scripts/build-pmos.sh on main
appends =y for them to the kernel config file. The display options appended the same way DID take effect (=y). As a module the
touch driver is loaded by userspace at about 6.5 s and first reads the chip at about 7 s; Samsung's driver reads it at 3.5 s
and gets a normal register map (F01, F12, F51). Built in, the first read happens as soon as the I2C bus is up, so dmesg shows
whether the chip is in touch mode that early.

What this script does: it adds a block at the end of the display check block in prepare() of the kernel package that
  1. prints the RMI4 lines of .config before,
  2. deletes and re-adds the RMI4 symbols as =y DIRECTLY in .config, runs olddefconfig,
  3. checks every one of them is =y and otherwise FAILS prepare() within minutes (no 25 minute wait), printing the RMI4
     lines and CONFIG_INPUT / CONFIG_I2C so the reason is visible in the log.
It is a diagnostic, not a fix.
"""
import sys

P = "scripts/build-pmos.sh"
ANCHOR = "# ---- pmos-a2corelte display backport end ----"

s = open(P).read()
if "pmos-a2corelte rmi builtin begin" in s:
    print("rmi builtin block already applied")
    sys.exit(0)

n = s.count(ANCHOR)
assert n == 1, "anchor not found exactly once (%d): %r" % (n, ANCHOR)

SYMS = "INPUT_TOUCHSCREEN RMI4_CORE RMI4_I2C RMI4_F01 RMI4_F11 RMI4_F12"
lines = [
    "# ---- pmos-a2corelte rmi builtin begin ----",
    "# the RMI4 touch driver must be built in (=y), see scripts/apply-rmi-builtin.py",
    r"""echo "pmos-a2corelte rmi: RMI4 config BEFORE: $(grep -E '^CONFIG_(INPUT_TOUCHSCREEN|RMI4_CORE|RMI4_I2C)=|^# CONFIG_RMI4_(CORE|I2C) is not set' .config | tr '\n' ' ')\"""".replace('\\"', '"'),
    "for _o in %s; do" % SYMS,
    r"""	sed -i "/^CONFIG_${_o}=/d;/^# CONFIG_${_o} is not set/d" .config""",
    "done",
    r"""printf '%s\n' CONFIG_INPUT_TOUCHSCREEN=y CONFIG_RMI4_CORE=y CONFIG_RMI4_I2C=y CONFIG_RMI4_F01=y CONFIG_RMI4_F11=y CONFIG_RMI4_F12=y >> .config""",
    'make ARCH="$_carch" LLVM=1 olddefconfig',
    "for _o in %s; do" % SYMS,
    r"""	grep -q "^CONFIG_${_o}=y" .config || { echo "pmos-a2corelte rmi: ERROR CONFIG_${_o} is not =y after olddefconfig"; grep -nE 'RMI4|^CONFIG_INPUT=|^CONFIG_I2C=|INPUT_TOUCHSCREEN' .config; return 1; }""",
    "done",
    r"""echo "pmos-a2corelte rmi: touch driver is built in: $(grep -E '^CONFIG_(RMI4_CORE|RMI4_I2C)=' .config | tr '\n' ' ')\"""".replace('\\"', '"'),
    "# ---- pmos-a2corelte rmi builtin end ----",
]
block = "\n\t".join(lines) + "\n\t"
s = s.replace(ANCHOR, block + ANCHOR)
assert s.count("pmos-a2corelte rmi builtin begin") == 1
open(P, "w").write(s)
print("scripts/build-pmos.sh patched: RMI4 forced to =y in prepare()")
