#!/usr/bin/env python3
"""
Boot fix (branch display-6.19): the Samsung PMIC driver is missing from the 6.19 kernel, so nothing that needs power starts.

Photos of the failing boot (initramfs pages 2 and 4): "devices_deferred" lists soc@0:usb@13600000, 13560000.mmc, 13540000.mmc and
i2c 2-004b (the touchscreen) all "wait for supplier /soc@0/i2c@10510000/pmic". The PMIC (Samsung S2MPU05, compatible
samsung,s2mpu05-pmic) never probed, so there are no regulators: eMMC, SD card and USB do not start (/proc/partitions is empty) and
the touchscreen has no supply.

Cause: in kernel 6.19 the Samsung PMIC MFD driver was split into drivers/mfd/sec-i2c.c (config MFD_SEC_I2C, new) and a common part
(MFD_SEC_CORE, now hidden and only selected by MFD_SEC_I2C). The old 6.15 kernel config has CONFIG_MFD_SEC_CORE=y; "make olddefconfig"
sets the new MFD_SEC_I2C to its default (n), so the driver is not built.

What this script does (edits scripts/build-pmos.sh in the CI checkout, run after apply-display-backport.py):
  1. kernel config: CONFIG_MFD_SEC_I2C=y, CONFIG_MFD_SEC_CORE=y (old name, harmless if hidden), CONFIG_REGULATOR_S2MPS11=y
  2. after olddefconfig in prepare(): fail within minutes if CONFIG_MFD_SEC_I2C=y or CONFIG_REGULATOR_S2MPS11=y did not survive,
     and log the PMIC-related config lines (work/kernel-touch-patch.log)
"""
import sys

P = "scripts/build-pmos.sh"
s = open(P).read()
if "pmos-a2corelte pmic" in s:
    print("pmic patch already applied")
    sys.exit(0)


def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, "anchor not found exactly once (%d): %r" % (n, old[:80])
    s = s.replace(old, new)


rep(
    """  grep -E 'TDDI|BACKLIGHT_CLASS|DRM_EXYNOS|DSIM|MIPI_VIDEO' "$KCFG" | tee -a work/kernel-touch-config.log || true
""",
    r"""  grep -E 'TDDI|BACKLIGHT_CLASS|DRM_EXYNOS|DSIM|MIPI_VIDEO' "$KCFG" | tee -a work/kernel-touch-config.log || true
  # pmos-a2corelte pmic: 6.19 split the Samsung PMIC driver (new symbol MFD_SEC_I2C); without it no regulators, no eMMC, no USB
  for o in MFD_SEC_I2C MFD_SEC_CORE REGULATOR_S2MPS11; do
    sed -i "/^CONFIG_${o}=/d;/^# CONFIG_${o} is not set/d" "$KCFG"
  done
  printf '%s\n' CONFIG_MFD_SEC_I2C=y CONFIG_MFD_SEC_CORE=y CONFIG_REGULATOR_S2MPS11=y >> "$KCFG"
  grep -E 'MFD_SEC|S2MPS11|S2MPU' "$KCFG" | tee -a work/kernel-touch-config.log || true
""",
)

rep(
    """	echo "pmos-a2corelte display: panel node, TDDI panel, DSI, DECON and MIPI PHY are all in the kernel"
""",
    r"""	echo "pmos-a2corelte kernel: PMIC config after olddefconfig: $(grep -E '^CONFIG_(MFD_SEC|REGULATOR_S2MPS11)' .config | tr '\n' ' ')"
	grep -q '^CONFIG_MFD_SEC_I2C=y' .config || { echo "pmos-a2corelte pmic: ERROR CONFIG_MFD_SEC_I2C=y is missing after olddefconfig (Samsung PMIC driver)"; return 1; }
	grep -q '^CONFIG_REGULATOR_S2MPS11=y' .config || { echo "pmos-a2corelte pmic: ERROR CONFIG_REGULATOR_S2MPS11=y is missing after olddefconfig"; return 1; }
	echo "pmos-a2corelte display: panel node, TDDI panel, DSI, DECON and MIPI PHY are all in the kernel"
""",
)

open(P, "w").write(s)
print("scripts/build-pmos.sh patched for the PMIC config")
