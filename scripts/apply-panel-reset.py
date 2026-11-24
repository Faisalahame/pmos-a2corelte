#!/usr/bin/env python3
"""
Touch fix (branch display-6.19): reset the TD4101 the way the stock Samsung kernel does.

Finding (stock dtsi arch/arm64/boot/dts/exynos7870-a2corelte_common.dtsi of the Samsung kernel source):
  decon_board { gpio_lcd_rst = <&gpd3 4 0>; ... }
  dsim_reset_panel: gpio high, wait 1 ms, gpio low, wait 1 ms, gpio high, wait 130 ms
The stock touchscreen node has NO reset and NO power property (only the irq gpio gpa0-6 and reset-delay-ms = 150). The TD4101 is touch + display
driver in ONE chip with ONE reset pin, so the stock DISPLAY driver resets it, and 130 ms later the touch part answers in register mode (stock reads it
at about 3.5 s and gets a normal register map).
Mainline 6.19 has no reset-gpios on the a2corelte panel node (and panel-synaptics-tddi.c treats it as optional), so nothing ever resets the chip after
the bootloader. It keeps whatever state it was left in: the fixed byte stream i2ctransfer returns for every register.

What this script does (edits scripts/build-pmos.sh in the CI checkout, run after apply-display-backport.py):
  1. devicetree: reset-gpios = <&gpd3 4 GPIO_ACTIVE_LOW> on the td4101 panel node (stock sequence is high-low-high, so the line is active low)
  2. panel driver: the reset gpio is requested as an output (not asserted), the wait after the reset is 130 ms (was 10 ms) like the stock driver,
     and a dev_info line "pmos-a2corelte: TD4101 reset done" shows in dmesg when it happened
  3. RMI4 touch driver is built as modules again (=m): the panel has to reset the chip BEFORE the touch driver reads it, and a module is
     loaded by userspace (about 6 s) after the display driver is up. dmesg order to check: "TD4101 reset done" must come before "pmos-a2corelte PDT".
"""
import sys

P = "scripts/build-pmos.sh"
s = open(P).read()
if "pmos-a2corelte panel reset" in s:
    print("panel reset patch already applied")
    sys.exit(0)


def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, "anchor not found exactly once (%d): %r" % (n, old[:80])
    s = s.replace(old, new)


T = "\t"
END = T + "# ---- pmos-a2corelte display backport end ----\n"
block = "\n".join([
    T + "# ---- pmos-a2corelte panel reset begin ----",
    T + "# TD4101 = touch + display driver in one chip with one reset pin: gpd3-4 (gpio_lcd_rst in the stock dtsi), see scripts/apply-panel-reset.py",
    T + r"""if ! grep -q 'reset-gpios = <&gpd3 4 GPIO_ACTIVE_LOW>' "$_dts"; then""",
    T + T + r'''awk '{ print } /compatible = "syna,td4101-panel";/ { print "\t\treset-gpios = <&gpd3 4 GPIO_ACTIVE_LOW>;" }' "$_dts" > "$_dts.new" && mv "$_dts.new" "$_dts"''',
    T + "fi",
    T + r"""grep -q 'reset-gpios = <&gpd3 4 GPIO_ACTIVE_LOW>' "$_dts" || { echo "pmos-a2corelte panel reset: ERROR reset-gpios was not added to $_dts"; return 1; }""",
    T + "_tddi=drivers/gpu/drm/panel/panel-synaptics-tddi.c",
    T + r'''sed -i 's|devm_gpiod_get_optional(dev, "reset", GPIOD_ASIS)|devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW)|' "$_tddi"''',
    T + r'''perl -0pi -e 's/(gpiod_set_value_cansleep\(ctx->reset_gpio, 0\);\n)\tusleep_range\(10000, 11000\);/$1\tmsleep(130);\n\tdev_info(dev, "pmos-a2corelte: TD4101 reset done\\n");/' "$_tddi"''',
    T + r"""grep -q 'GPIOD_OUT_LOW' "$_tddi" || { echo "pmos-a2corelte panel reset: ERROR reset gpio flag was not changed in $_tddi"; return 1; }""",
    T + r"""grep -q 'msleep(130)' "$_tddi" || { echo "pmos-a2corelte panel reset: ERROR the 130 ms wait was not added to $_tddi"; return 1; }""",
    T + r'''grep -n 'reset-gpios' "$_dts"; grep -n 'reset_gpio\|msleep(130)\|TD4101 reset' "$_tddi"''',
    T + 'echo "pmos-a2corelte panel reset: reset-gpios gpd3-4 on the td4101 panel, 130 ms wait after the reset"',
    T + "# ---- pmos-a2corelte panel reset end ----",
]) + "\n"
rep(END, block + END)

# RMI4 touch driver: modules again (the chip must be reset by the panel before the touch driver reads it)
rep(
    "CONFIG_RMI4_CORE=y CONFIG_RMI4_I2C=y CONFIG_RMI4_F01=y CONFIG_RMI4_F11=y CONFIG_RMI4_F12=y",
    "CONFIG_RMI4_CORE=m CONFIG_RMI4_I2C=m CONFIG_RMI4_F01=m CONFIG_RMI4_F11=m CONFIG_RMI4_F12=m",
)

open(P, "w").write(s)
print("scripts/build-pmos.sh patched: panel reset-gpios gpd3-4, 130 ms wait, RMI4 as modules")
