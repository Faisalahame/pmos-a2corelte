#!/usr/bin/env python3
"""
Wi-Fi fix (branch display-6.19): the Wi-Fi chip on kernel 6.19 fails with "dongle is not responding" (-110).

Two findings, both taken from the phone's own stock firmware (vendor.img and boot.img from the SM-A260G):
  1. The Wi-Fi chip is a BCM43436B0 (xtalfreq 37.4 MHz). The image only had the Raspberry Pi Zero 2 W NVRAM for it.
     The phone's own NVRAM (stock /vendor/etc/wifi/nvram.txt_36) is now installed by scripts/setup-wifi-ssh.sh.
  2. The stock device tree sets the Wi-Fi host-wake pin (gpa2-2) to pull-up through the "wlan" node (pinctrl cfg-wlanhostwake).
     The mainline a2corelte device tree defines that pin config (wlan_hostwake) but never references it, so the pin is left
     as the bootloader had it.

What this script does (edits scripts/build-pmos.sh in the CI checkout, run after apply-pmic-fix.py):
  in prepare(), before the kernel is built: add &wlan_hostwake to the pinctrl-0 list of the mmc1 node in
  arch/arm64/boot/dts/exynos/exynos7870-a2corelte.dts. If that line is not there (a patch changed it), the build only prints a
  warning and goes on.
"""
import sys

P = "scripts/build-pmos.sh"
s = open(P).read()
if "pmos-a2corelte wifi" in s:
    print("wifi patch already applied")
    sys.exit(0)

old = """	echo "pmos-a2corelte display: panel node, TDDI panel, DSI, DECON and MIPI PHY are all in the kernel"
"""
new = r"""	# pmos-a2corelte wifi: apply the host-wake pin config (pull-up) of the Wi-Fi chip, which the stock tree sets and mainline never references
	WDTS=arch/arm64/boot/dts/exynos/exynos7870-a2corelte.dts
	if grep -q 'sd1_bus4>;' "$WDTS" && grep -q 'wlan_hostwake:' "$WDTS"; then
		sed -i 's|&sd1_bus1 &sd1_bus4>;|\&sd1_bus1 \&sd1_bus4 \&wlan_hostwake>;|' "$WDTS"
		grep -n 'wlan_hostwake' "$WDTS" || true
		echo "pmos-a2corelte wifi: wlan_hostwake added to the mmc1 pinctrl list"
	else
		echo "pmos-a2corelte wifi: WARNING mmc1 pinctrl line or wlan_hostwake not found in $WDTS, device tree left unchanged"
	fi
""" + old

assert s.count(old) == 1, "anchor not found exactly once (%d)" % s.count(old)
s = s.replace(old, new)
open(P, "w").write(s)
print("scripts/build-pmos.sh patched for the Wi-Fi host-wake pin")
