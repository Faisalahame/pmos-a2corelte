#!/usr/bin/env python3
"""
Display backport for the a2corelte touchscreen (branch display-6.19).

Why: the touchscreen chip is a Synaptics TD4101 (touch + display driver in one IC). Kernel 6.15 has no DSI controller
driver / MIPI PHY / panel driver for it on Exynos7870, so pmOS only shows the bootloader's framebuffer (simpledrm) and
never runs the TD4101 display init. Everything that is missing is upstream in mainline 6.19:
  - DECON, DSIM (12 patches), MIPI PHY, DSI devicetree nodes, the a2corelte panel node (simple-framebuffer removed)
  - drivers/gpu/drm/panel/panel-synaptics-tddi.c  (DRM_PANEL_SYNAPTICS_TDDI)

What this script does: it edits scripts/build-pmos.sh in the CI checkout (the file in git is not changed) so that the
kernel package is built from mainline 6.19.x instead of 6.15:
  1. pkgver -> 6.19.x
  2. the exynos7870-mainline patch set is applied TOLERANTLY: a patch that does not apply cleanly (usually because it is
     already in mainline) is skipped and logged as "pmos-a2corelte kernel: SKIPPED patch ..."
  3. devicetrees that already exist in mainline (a2corelte!) are kept, not overwritten by the old 6.15 copies
  4. kernel config: TDDI panel + backlight on; "make olddefconfig" for the new kernel
  5. prepare() checks that panel node, panel driver, DSI, MIPI PHY and DECON support are really in the tree, else it fails
     within minutes
  6. (run of 23:12) the old patch set's battery fuel gauge driver s2mu005_fg.c does not compile on 6.19 (struct
     power_supply_config has no of_node any more): prepare() rewrites power_supply_config.of_node -> fwnode
  7. (run of 00:23) the kernel built; the boot image step failed in dtbTool-exynos: mainline's a2corelte dtb has no
     model_info-* properties -> they are added to the dts in prepare()
  8. speed: kernel config without debug info / BTF (the first full build took 55 minutes)
The touchscreen fixes (rmi4 changes) stay as they were.
"""
import sys

P = "scripts/build-pmos.sh"
KPKGVER = "6.19.6"

s = open(P).read()
if "pmos-a2corelte display backport" in s:
    print("display backport already applied")
    sys.exit(0)


def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, "anchor not found exactly once (%d): %r" % (n, old[:80])
    s = s.replace(old, new)


# ---- 1. kernel config -------------------------------------------------------------------------------------------
rep(
    """  grep -E 'I2C_CHARDEV' "$KCFG" | tee -a work/kernel-touch-config.log || true
""",
    """  grep -E 'I2C_CHARDEV' "$KCFG" | tee -a work/kernel-touch-config.log || true
  # pmos-a2corelte display backport: TD4101 panel driver (mainline 6.19) and what it needs
  for o in DRM_PANEL_SYNAPTICS_TDDI BACKLIGHT_CLASS_DEVICE DRM_EXYNOS DRM_EXYNOS7_DECON DRM_EXYNOS_DSI DRM_SAMSUNG_DSIM PHY_EXYNOS_MIPI_VIDEO; do
    sed -i "/^CONFIG_${o}=/d;/^# CONFIG_${o} is not set/d" "$KCFG"
  done
  printf '%s\\n' CONFIG_BACKLIGHT_CLASS_DEVICE=y CONFIG_DRM_EXYNOS=y CONFIG_DRM_EXYNOS7_DECON=y CONFIG_DRM_EXYNOS_DSI=y \\
    CONFIG_DRM_SAMSUNG_DSIM=y CONFIG_PHY_EXYNOS_MIPI_VIDEO=y CONFIG_DRM_PANEL_SYNAPTICS_TDDI=y >> "$KCFG"
  grep -E 'TDDI|BACKLIGHT_CLASS|DRM_EXYNOS|DSIM|MIPI_VIDEO' "$KCFG" | tee -a work/kernel-touch-config.log || true
  # faster kernel build: no debug info / BTF (DWARF + pahole were most of the 55 minute compile)
  sed -i '/^CONFIG_DEBUG_INFO/d;/^# CONFIG_DEBUG_INFO/d;/^CONFIG_MODULE_ALLOW_BTF_MISMATCH/d;/^# CONFIG_MODULE_ALLOW_BTF_MISMATCH/d' "$KCFG"
  printf '%s\\n' CONFIG_DEBUG_INFO_NONE=y >> "$KCFG"
  grep -E 'DEBUG_INFO|BTF' "$KCFG" | tee -a work/kernel-touch-config.log || true
""",
)

# ---- 2. kernel version + tolerant patching in the kernel APKBUILD ---------------------------------------------------
rep(
    """sed -i 's/^pkgrel=.*/pkgrel=99/' "$KDIR/APKBUILD"
""",
    """sed -i 's/^pkgrel=.*/pkgrel=99/' "$KDIR/APKBUILD"
# pmos-a2corelte display backport: build mainline %(v)s instead of 6.15 (it has DSIM, MIPI PHY, TDDI panel and the a2corelte panel node)
export KPKGVER=%(v)s
python3 - "$KDIR/APKBUILD" <<'PYEOF'
import os, sys
p = sys.argv[1]
t = open(p).read()
def rep(old, new):
    global t
    assert t.count(old) == 1, "APKBUILD anchor missing or not unique: " + old[:60]
    t = t.replace(old, new)
rep("pkgver=6.15\\n", "pkgver=" + os.environ["KPKGVER"] + "\\n")
rep("\\t\\tpatch -p1 < \\"$patchfile\\"\\n", "\\n".join([
 "\\t\\tif patch -p1 -N --dry-run < \\"$patchfile\\" >/dev/null 2>&1; then",
 "\\t\\t\\tpatch -p1 -N < \\"$patchfile\\"",
 "\\t\\telse",
 "\\t\\t\\techo \\"pmos-a2corelte kernel: SKIPPED patch $(basename \\"$patchfile\\") (already in mainline or does not apply)\\"",
 "\\t\\tfi", ""]))
rep("\\t\\tcp \\"$dts\\" \\"arch/arm64/boot/dts/exynos/\\"\\n", "\\n".join([
 "\\t\\tif [ -e \\"arch/arm64/boot/dts/exynos/$(basename \\"$dts\\")\\" ]; then",
 "\\t\\t\\techo \\"pmos-a2corelte kernel: KEEPING mainline $(basename \\"$dts\\")\\"",
 "\\t\\t\\tcontinue",
 "\\t\\tfi",
 "\\t\\tcp \\"$dts\\" \\"arch/arm64/boot/dts/exynos/\\"", ""]))
open(p, "w").write(t)
print("kernel APKBUILD: mainline", os.environ["KPKGVER"], "with tolerant patching")
PYEOF
""" % {"v": KPKGVER},
)

# ---- 3. checks + olddefconfig at the end of prepare() ---------------------------------------------------------------
rep(
    """grep -c 'RMI_I2C_RETRIES' work/touch-inject.sh
""",
    """grep -c 'RMI_I2C_RETRIES' work/touch-inject.sh

cat > work/touch-inject-display.sh <<'EOS'
	# ---- pmos-a2corelte display backport begin ----
	_dts=arch/arm64/boot/dts/exynos/exynos7870-a2corelte.dts
	grep -q 'syna,td4101-panel' "$_dts" || { echo "pmos-a2corelte display: ERROR $_dts has no syna,td4101-panel node"; return 1; }
	[ -f drivers/gpu/drm/panel/panel-synaptics-tddi.c ] || { echo "pmos-a2corelte display: ERROR panel-synaptics-tddi.c is not in this kernel"; return 1; }
	grep -q 'exynos7870-mipi-dsi' drivers/gpu/drm/exynos/exynos_drm_dsi.c || { echo "pmos-a2corelte display: ERROR no exynos7870 DSI glue"; return 1; }
	grep -q 'exynos7870-mipi-video-phy' drivers/phy/samsung/phy-exynos-mipi-video.c || { echo "pmos-a2corelte display: ERROR no exynos7870 MIPI PHY"; return 1; }
	grep -q 'exynos7870-decon' drivers/gpu/drm/exynos/exynos7_drm_decon.c || { echo "pmos-a2corelte display: ERROR no exynos7870 DECON"; return 1; }
	if grep -q 'simple-framebuffer' "$_dts"; then echo "pmos-a2corelte display: WARN simple-framebuffer is still in $_dts"; fi
	make ARCH="$_carch" LLVM=1 olddefconfig
	for _o in DRM_PANEL_SYNAPTICS_TDDI DRM_EXYNOS_DSI DRM_SAMSUNG_DSIM DRM_EXYNOS7_DECON PHY_EXYNOS_MIPI_VIDEO BACKLIGHT_CLASS_DEVICE; do
		grep -q "^CONFIG_${_o}=y" .config || { echo "pmos-a2corelte display: ERROR CONFIG_${_o}=y is missing after olddefconfig"; return 1; }
	done
	echo "pmos-a2corelte display: panel node, TDDI panel, DSI, DECON and MIPI PHY are all in the kernel"
	# ---- pmos-a2corelte display backport end ----
EOS
awk -v f=work/touch-inject-display.sh '/# ---- pmos-a2corelte touch fix end ----/ { while ((getline l < f) > 0) print l; close(f) } { print }' work/touch-inject.sh > work/touch-inject.sh.new \\
  && mv work/touch-inject.sh.new work/touch-inject.sh
grep -c 'pmos-a2corelte display backport' work/touch-inject.sh
""",
)

# ---- 4. log the new messages, and expect the new package version ----------------------------------------------------
rep(
    """grep -aE 'pmos-a2corelte touch fix' "$WORK/log.txt" 2>/dev/null | tail -n 30 | tee work/kernel-touch-patch.log || true""",
    """grep -aE 'pmos-a2corelte (touch fix|kernel:|display)' "$WORK/log.txt" 2>/dev/null | tail -n 200 | tee work/kernel-touch-patch.log || true""",
)
assert "6.15-r99" in s
s = s.replace("6.15-r99", "${KPKGVER}-r99")

# ---- 5. 6.19 API fix: struct power_supply_config lost its of_node member (use fwnode) ----------------------------
# The old exynos7870 patch set adds drivers (s2mu005_fg.c = battery fuel gauge) written for 6.15; they apply but do not compile.
rep(
    """	make ARCH="$_carch" LLVM=1 olddefconfig
""",
    r"""	# 6.19: struct power_supply_config has no of_node any more -> fwnode (fixes s2mu005_fg.c from the old patch set)
	for _f in drivers/power/supply/*.c; do
		grep -q 'struct power_supply_config' "$_f" || continue
		perl -0pi -e 'my %v; while (/struct[[:space:]]+power_supply_config[[:space:]]+[*]?[[:space:]]*([A-Za-z0-9_]+)/g) { $v{$1} = 1; } foreach my $n (keys %v) { s/(?<![A-Za-z0-9_])$n([.]|->)of_node[[:space:]]*=[[:space:]]*([^;]+);/$n${1}fwnode = of_fwnode_handle($2);/g; }' "$_f"
		if grep -q 'of_fwnode_handle' "$_f" && ! grep -q '<linux/of.h>' "$_f"; then
			sed -i '0,/^#include </s||#include <linux/of.h>\n#include <|' "$_f"
		fi
		echo "pmos-a2corelte kernel: power_supply of_node->fwnode check $_f: $(grep -c 'fwnode = of_fwnode_handle' "$_f") fixed, $(grep -c '[.>]of_node' "$_f") of_node left"
	done
	make ARCH="$_carch" LLVM=1 olddefconfig
""",
)

# ---- 6. list ALL compile errors when the build fails -------------------------------------------------------------------
rep(
    """| tail -n 40 | cut -c1-300 | tee work/pmb-kernel-errors.log || true
""",
    """| tail -n 40 | cut -c1-300 | tee work/pmb-kernel-errors.log || true
  { grep -aE 'pmos-a2corelte (kernel|display)' "$WORK/log.txt" 2>/dev/null | sort -u | head -n 40
    grep -aE ' error: |undefined reference|ld.lld: error|Error 1$' "$WORK/log.txt" 2>/dev/null | sort -u | head -n 60; } \\
    | cut -c1-300 | tee work/pmb-compile-errors.log || true
""",
)

# ---- 7. dtbTool-exynos needs model_info-* in the root of the dtb (run of 00:23: "could not load device tree blobs") ------
rep(
    """	make ARCH="$_carch" LLVM=1 olddefconfig
""",
    r"""	# dtbTool-exynos (boot-deploy builds the Samsung dt.img with it) needs model_info-* in the root of the dtb. Mainline 6.19
	# dropped them; same values as the old exynos7870 patch set / the first upstream submission.
	if ! grep -q 'model_info-chip' "$_dts" arch/arm64/boot/dts/exynos/exynos7870.dtsi; then
		awk '{ print } /^[[:space:]]*compatible = "samsung,a2corelte"/ { print "\tmodel_info-hw_rev = <0>;"; print "\tmodel_info-hw_rev_end = <255>;"; print "\tmodel_info-chip = <7870>;" }' "$_dts" > "$_dts.new" && mv "$_dts.new" "$_dts"
	fi
	grep -q 'model_info-chip' "$_dts" arch/arm64/boot/dts/exynos/exynos7870.dtsi || { echo "pmos-a2corelte display: ERROR no model_info-chip in the devicetree (dtbTool-exynos needs it)"; return 1; }
	echo "pmos-a2corelte display: $(grep -h 'model_info' "$_dts" arch/arm64/boot/dts/exynos/exynos7870.dtsi | tr -d '\t\n')"
	make ARCH="$_carch" LLVM=1 olddefconfig
	echo "pmos-a2corelte kernel: lines CONFIG_DEBUG_INFO_BTF=y in .config: $(grep -c '^CONFIG_DEBUG_INFO_BTF=y' .config) (0 = off)"
""",
)

open(P, "w").write(s)
print("scripts/build-pmos.sh patched for the display backport (kernel %s)" % KPKGVER)
