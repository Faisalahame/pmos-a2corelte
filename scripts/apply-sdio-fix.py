#!/usr/bin/env python3
"""
Wi-Fi SDIO fix (branch display-6.19): with the A2 Core NVRAM the Wi-Fi chip now starts and joins the hotspot, but the
SDIO bus corrupts data (dmesg: "HW header checksum error", "bad data offset", "max tx seq number error", "resumed on
timeout", GET STA INFO -110): the connection is up but very slow and unreliable. The CPU is 85 % idle and memory is
fine, so this is the bus, not the system.

Most likely cause: the mmc1 (SDIO) card clock is too fast for the sample/drive timing in the mainline tree. The mainline
a2corelte tree allows SD high-speed (50 MHz) on mmc1 and sets no clock limit.

What this script does (edits scripts/build-pmos.sh in the CI checkout, run after apply-pmic-fix.py):
  in prepare(), before the kernel is built: inside the &mmc1 node of arch/arm64/boot/dts/exynos/exynos7870-a2corelte.dts
  remove cap-sd-highspeed and add max-frequency = <25000000> (25 MHz). If the node is not as expected the build only
  prints a warning and goes on.
"""
import sys

P = "scripts/build-pmos.sh"
s = open(P).read()
if "pmos-a2corelte sdio" in s:
    print("sdio patch already applied")
    sys.exit(0)

old = """\techo "pmos-a2corelte display: panel node, TDDI panel, DSI, DECON and MIPI PHY are all in the kernel"
"""
new = """\t# pmos-a2corelte sdio: limit the Wi-Fi SDIO clock of mmc1 to 25 MHz (SDIO data errors at the default speed)
\tSDTS=arch/arm64/boot/dts/exynos/exynos7870-a2corelte.dts
\tif grep -q '^&mmc1 {' "$SDTS"; then
\t\tsed -i '/^&mmc1 {/,/^};/{/^[[:space:]]*cap-sd-highspeed;$/d;/^[[:space:]]*max-frequency = /d;s|^\\([[:space:]]*\\)cap-sdio-irq;$|&\\n\\1max-frequency = <25000000>;|}' "$SDTS"
\t\tif sed -n '/^&mmc1 {/,/^};/p' "$SDTS" | grep -q 'max-frequency = <25000000>'; then
\t\t\techo "pmos-a2corelte sdio: mmc1 limited to 25 MHz"
\t\t\tsed -n '/^&mmc1 {/,/^};/p' "$SDTS"
\t\telse
\t\t\techo "pmos-a2corelte sdio: WARNING max-frequency was not added (no cap-sdio-irq line in &mmc1?), device tree left as is"
\t\tfi
\telse
\t\techo "pmos-a2corelte sdio: WARNING &mmc1 node not found in $SDTS, device tree left unchanged"
\tfi
""" + old

assert s.count(old) == 1, "anchor not found exactly once (%d)" % s.count(old)
open(P, "w").write(s.replace(old, new))
print("scripts/build-pmos.sh patched for the SDIO clock limit")
