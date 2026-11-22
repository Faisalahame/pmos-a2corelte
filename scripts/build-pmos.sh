#!/usr/bin/env bash
# Builds postmarketOS for the Samsung Galaxy A2 Core (a2corelte) with pmbootstrap.
# Output:
#   out/boot.img         kernel + pmOS initramfs (make-boot.py turns it into the small boot image the phone needs)
#   work/pmos-root.img   the pmOS root filesystem as a bare ext4 image (label pmOS_root)
#
# NOTE: postmarketOS dropped the per-phone package device-samsung-a2corelte in May 2026
# ("Switch to generic port samsung-exynos7"). The generic port has no Android boot.img support,
# but the old per-phone package had it. So we build the generic port (with its close-to-mainline
# exynos7870 kernel) and copy the old a2corelte boot.img settings (offsets, page size, cmdline,
# dtb, mkbootimg/dtbtool) from pmaports git history into it.
#
# TOUCHSCREEN: the kernel is built FROM SOURCE with two small touchscreen changes (see "touchscreen" below).
#
# env: UI = postmarketOS user interface (default phosh)
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work out
exec > >(tee -a work/pmos.log) 2>&1

UI="${UI:-phosh}"
PMOS_USER=user
PMOS_PASS=147147
PMOS_HOST=a2corelte
EXTRA_PKGS="openssh,e2fsprogs-extra,nano"

WORK="$HOME/.local/var/pmbootstrap"
PMAPORTS="$WORK/cache_git/pmaports"

# On any failure print the interesting lines of pmbootstrap's own log
on_err() {
  set +x
  echo "== pmbootstrap log: error lines =="
  grep -aiE 'error|unable to select|no such package|required by|conflict|not found|failed|satisf|breaks' "$WORK/log.txt" 2>/dev/null \
    | grep -av 'APKINDEX\|Unable to find\|Error relocating' | tail -n 30 | cut -c1-300 | tee work/pmb-errors.log || true
  # kernel build logs (the touchscreen patch runs in the kernel package's prepare step)
  grep -aE 'a2core touch|pmos-a2corelte touch|\*\*\*|error:|Error [0-9]' "$WORK/log.txt" 2>/dev/null | tail -n 40 | cut -c1-300 | tee work/pmb-kernel-errors.log || true
}
trap on_err ERR

# gitlab.postmarketos.org sometimes answers 502 ("GitLab is not responding"): retry, then try the gitlab.com mirror
clone_retry() {
  local dest="$1" depth="$2" name="$3" u n
  for u in "https://gitlab.postmarketos.org/postmarketOS/$name.git" "https://gitlab.com/postmarketOS/$name.git"; do
    for n in 1 2 3 4 5; do
      rm -rf "$dest"
      if git clone ${depth:+--depth=1} "$u" "$dest"; then return 0; fi
      echo "WARN: clone of $u failed (try $n/5), waiting"; sleep $((n*20))
    done
  done
  echo "ERROR: could not clone $name from any server"; return 1
}

# pmbootstrap is no longer on PyPI (all versions yanked) -> install from git
clone_retry "$HOME/pmbootstrap" 1 pmbootstrap
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --break-system-packages "$HOME/pmbootstrap" \
  || ln -sf "$HOME/pmbootstrap/pmbootstrap.py" "$HOME/.local/bin/pmbootstrap"
pmbootstrap --version

# pmaports (device + kernel packages) in pmbootstrap's default location
if [ ! -d "$PMAPORTS/.git" ]; then
  mkdir -p "$(dirname "$PMAPORTS")"
  clone_retry "$PMAPORTS" "" pmaports
fi
git -C "$PMAPORTS" remote -v
git -C "$PMAPORTS" log --oneline -n 1

# The work folder normally gets its "version" file from "pmbootstrap init".
WORKVER=$(python3 -c 'import pmb.config as c; print(c.work_version)' 2>/dev/null || echo 8)
echo "$WORKVER" > "$WORK/version"

restore_pkg() {
  local pkg="$1" found c p d
  found=$(find "$PMAPORTS/device" -maxdepth 2 -type d -name "$pkg" | head -n1)
  if [ -n "$found" ]; then
    echo "FOUND $pkg at $found"
    return 0
  fi
  c=$(git -C "$PMAPORTS" log --all --diff-filter=D --format=%H -n1 -- "device/*/$pkg/APKBUILD" || true)
  [ -n "$c" ] || { echo "ERROR: $pkg is not in pmaports and was never deleted from it"; return 1; }
  p=$(git -C "$PMAPORTS" show --name-only --format= "$c" -- "device/*/$pkg/APKBUILD" | head -n1)
  d=$(dirname "$p")
  git -C "$PMAPORTS" checkout "$c^" -- "$d"
  echo "RESTORED $pkg from $c^ into $d"
}

GENERIC=$(find "$PMAPORTS/device" -maxdepth 2 -type d -name device-samsung-exynos7 | head -n1)
if [ -n "$GENERIC" ]; then
  DEVICE=samsung-exynos7
else
  DEVICE=samsung-a2corelte
  restore_pkg "device-$DEVICE"
  restore_pkg linux-postmarketos-exynos7870 || true
fi
echo "DEVICE=$DEVICE UI=$UI"

# pmbootstrap refuses to run (even "config") until a config file exists,
# and "pmbootstrap init" is interactive -> write a minimal config ourselves.
mkdir -p "$HOME/.config"
cat > "$HOME/.config/pmbootstrap_v3.cfg" <<EOF
[pmbootstrap]
device = $DEVICE
ui = $UI
user = $PMOS_USER
EOF

pmbootstrap -y config device "$DEVICE"
pmbootstrap -y config ui "$UI"
pmbootstrap -y config user "$PMOS_USER"
pmbootstrap -y config hostname "$PMOS_HOST"
pmbootstrap -y config extra_packages "$EXTRA_PKGS" || echo "WARN: extra_packages not accepted"
# close-to-mainline Exynos 7870 kernel variant of the generic port
pmbootstrap -y config kernel exynos7870 || echo "WARN: kernel option 'exynos7870' not accepted, keeping default"

if [ "$DEVICE" = samsung-exynos7 ]; then
  # ---- give the generic port the old a2corelte Android boot.img settings ----
  OLDC=$(git -C "$PMAPORTS" log --all --diff-filter=D --format=%H -n1 -- 'device/*/device-samsung-a2corelte/APKBUILD' || true)
  if [ -n "$OLDC" ]; then
    OLDP=$(git -C "$PMAPORTS" show --name-only --format= "$OLDC" -- 'device/*/device-samsung-a2corelte/deviceinfo' | head -n1)
    OLDD=$(dirname "$OLDP")
    git -C "$PMAPORTS" show "$OLDC^:$OLDP" > work/old-deviceinfo
    git -C "$PMAPORTS" show "$OLDC^:$OLDD/APKBUILD" > work/old-APKBUILD
    echo "===== OLD a2corelte deviceinfo ====="; cat work/old-deviceinfo
    echo "===== OLD a2corelte APKBUILD ====="; cat work/old-APKBUILD
    grep -E '^deviceinfo_(flash_|bootimg_|generate_bootimg|dtb|kernel_cmdline|header_version|append_dtb)' work/old-deviceinfo > work/old-keys || true
    echo "===== keys copied into generic deviceinfo ====="; cat work/old-keys
    if [ -s work/old-keys ]; then
      cut -d= -f1 work/old-keys | while read -r k; do sed -i "/^$k=/d" "$GENERIC/deviceinfo"; done
      cat work/old-keys >> "$GENERIC/deviceinfo"
    fi
  else
    echo "WARN: could not find the old a2corelte package in pmaports history"
  fi
  # tools that mkinitfs needs inside the rootfs to create boot.img (the old package depended on these)
  sed -i '0,/^\tsystemd-boot$/s//\tsystemd-boot\n\tmkbootimg\n\tdtbtool-exynos\n\tmesa-dri-simpledrm/' "$GENERIC/APKBUILD"
  # bump pkgrel so pmbootstrap builds our modified package instead of using the mirror's binary
  sed -i 's/^pkgrel=.*/pkgrel=99/' "$GENERIC/APKBUILD"
  pmbootstrap -y checksum device-samsung-exynos7
  echo "===== patched generic deviceinfo ====="; cat "$GENERIC/deviceinfo"
  echo "===== patched generic APKBUILD (head) ====="; head -n 25 "$GENERIC/APKBUILD"
fi

# ---- touchscreen ----
# The A2 Core touchscreen is a Synaptics TD4101 (touch + display driver in one chip) on I2C address 0x4b, used with the
# kernel's RMI4 driver (devicetree: syna,rmi4-i2c). The stock (TWRP) driver never resets the chip; the mainline driver
# sends a reset command right away and, with the stock devicetree, talks to the chip without any start-up delay.
# Result on the phone (pmos-diag): "RMI initial reset failed", then a duplicate rmi4-00.fn34 (the chip answers like
# one in bootloader mode) and no touch input device. So the kernel is built from source with two changes:
#   1. devicetree: syna,startup-delay-ms / syna,reset-delay-ms = 500 ms on the touchscreen node
#   2. rmi_driver.c: no initial reset command (just a 500 ms wait), like the stock Samsung driver
# The kernel package (linux-postmarketos-exynos7870) gets a small block in its prepare() that does this.
KDIR=$(find "$PMAPORTS" -maxdepth 4 -type d -name linux-postmarketos-exynos7870 | head -n1 || true)
KCFG=""
if [ -n "$KDIR" ]; then
  KCFG=$(ls "$KDIR"/config-*.aarch64 2>/dev/null | head -n1 || true)
fi
if [ -n "$KCFG" ]; then
  echo "===== kernel config: $KCFG ====="
  grep -E 'RMI4|INPUT_TOUCHSCREEN|^CONFIG_I2C=|I2C_S3C|I2C_EXYNOS' "$KCFG" | tee work/kernel-touch-config.log || true
  if grep -qE '^CONFIG_RMI4_I2C=[ym]' "$KCFG" && grep -qE '^CONFIG_RMI4_F12=[ym]' "$KCFG"; then
    echo "RMI4 touchscreen drivers are already enabled in the kernel config"
  else
    echo "RMI4 touchscreen drivers are MISSING from the kernel config -> enabling them"
    for o in INPUT_TOUCHSCREEN RMI4_CORE RMI4_I2C RMI4_F01 RMI4_F11 RMI4_F12; do
      sed -i "/^CONFIG_${o}=/d;/^# CONFIG_${o} is not set/d" "$KCFG"
    done
    echo >> "$KCFG"
    printf '%s\n' CONFIG_INPUT_TOUCHSCREEN=y CONFIG_RMI4_CORE=y CONFIG_RMI4_I2C=y CONFIG_RMI4_F01=y CONFIG_RMI4_F11=y CONFIG_RMI4_F12=y >> "$KCFG"
  fi
else
  echo "WARN: kernel config of linux-postmarketos-exynos7870 not found in pmaports"
fi

if [ -z "$KDIR" ] || [ ! -f "$KDIR/APKBUILD" ]; then
  echo "ERROR: linux-postmarketos-exynos7870 is not in pmaports, cannot apply the touchscreen fix"
  exit 1
fi
echo "===== kernel APKBUILD (before the touchscreen patch) ====="; cat "$KDIR/APKBUILD"

# the block that goes into prepare() (runs in the kernel source directory, Alpine ash)
cat > work/touch-inject.sh <<'EOS'
	# ---- pmos-a2corelte touch fix begin ----
	_touch_dts=$(grep -rl 'syna,rmi4-i2c' arch/arm64/boot/dts/exynos/ | grep -v Makefile || true)
	[ -n "$_touch_dts" ] || { echo "pmos-a2corelte touch fix: ERROR no touchscreen node in the devicetrees"; return 1; }
	for _f in $_touch_dts; do
		awk '{ print } /compatible = "syna,rmi4-i2c";/ { print "\t\tsyna,startup-delay-ms = <500>;"; print "\t\tsyna,reset-delay-ms = <500>;" }' "$_f" > "$_f.new" && mv "$_f.new" "$_f"
		echo "pmos-a2corelte touch fix: devicetree patched: $_f"
		grep -n 'syna,' "$_f"
	done
	_touch_rd=drivers/input/rmi4/rmi_driver.c
	grep -q 'rmi_scan_pdt(rmi_dev, NULL, rmi_initial_reset)' "$_touch_rd" || { echo "pmos-a2corelte touch fix: ERROR rmi_initial_reset call not found in $_touch_rd"; return 1; }
	sed -i 's|retval = rmi_scan_pdt(rmi_dev, NULL, rmi_initial_reset);|msleep(500); retval = 0; /* pmos-a2corelte: no initial reset, like the stock driver */|' "$_touch_rd"
	grep -q '<linux/delay.h>' "$_touch_rd" || sed -i '0,/#include <linux\/module.h>/s||#include <linux/module.h>\n#include <linux/delay.h>|' "$_touch_rd"
	grep -n 'pmos-a2corelte\|linux/delay.h' "$_touch_rd"
	# ---- pmos-a2corelte touch fix end ----
EOS

if grep -q 'pmos-a2corelte touch fix begin' "$KDIR/APKBUILD"; then
  echo "touchscreen patch already in the kernel APKBUILD"
elif grep -qE '^[[:space:]]+default_prepare' "$KDIR/APKBUILD"; then
  sed -i '/^[[:space:]]*default_prepare/ r work/touch-inject.sh' "$KDIR/APKBUILD"
elif grep -q '^prepare()' "$KDIR/APKBUILD"; then
  sed -i '/^prepare()/ r work/touch-inject.sh' "$KDIR/APKBUILD"
else
  { printf '\nprepare() {\n\tdefault_prepare\n'; cat work/touch-inject.sh; printf '}\n'; } >> "$KDIR/APKBUILD"
fi
grep -q 'pmos-a2corelte touch fix begin' "$KDIR/APKBUILD" || { echo "ERROR: could not insert the touchscreen patch into the kernel APKBUILD"; exit 1; }
# build the kernel from source instead of using the mirror's binary
sed -i 's/^pkgrel=.*/pkgrel=99/' "$KDIR/APKBUILD"
pmbootstrap -y checksum linux-postmarketos-exynos7870
echo "===== kernel prepare() after the touchscreen patch ====="
sed -n '/^prepare()/,/^}/p' "$KDIR/APKBUILD"

pmbootstrap config || true

# --split: boot and root as two separate images (we only use the bare root filesystem).
# First try the default service manager. If installing the rootfs fails (an earlier run died in apk with
# "failed to commit usr/bin/udevadm / usr/sbin/init" from the systemd-edge repo), retry once with OpenRC.
if ! pmbootstrap -y install --split --password "$PMOS_PASS"; then
  echo "WARN: pmbootstrap install failed with the default service manager -> retrying with OpenRC"
  cp -f "$WORK/log.txt" work/pmb-install-systemd-attempt.log 2>/dev/null || true
  pmbootstrap -y zap || true
  pmbootstrap -y config service_manager openrc \
    || pmbootstrap -y config systemd never \
    || echo "WARN: neither 'service_manager openrc' nor 'systemd never' was accepted by this pmbootstrap"
  pmbootstrap config | grep -iE 'service_manager|systemd' || true
  pmbootstrap -y install --split --password "$PMOS_PASS"
fi

CH="$WORK/chroot_rootfs_$DEVICE"
echo "== rootfs /boot =="
sudo ls -la "$CH/boot" || true

# which kernel is really in the rootfs (must be our own r99 build with the touchscreen patch)
echo "== kernel package in the rootfs =="
sudo chroot "$CH" apk info -v 2>/dev/null | grep -i linux-postmarketos || true
grep -aE 'pmos-a2corelte touch fix' "$WORK/log.txt" 2>/dev/null | tail -n 20 | tee work/kernel-touch-patch.log || true

rm -rf /tmp/pmos-export
pmbootstrap -y export /tmp/pmos-export
ls -laL /tmp/pmos-export

BOOT=$(ls /tmp/pmos-export/boot.img* 2>/dev/null | head -n1 || true)
if [ -z "$BOOT" ]; then
  echo "ERROR: pmbootstrap did not produce a boot.img (see the old deviceinfo / patched deviceinfo above)"
  exit 1
fi
cp -L "$BOOT" out/boot.img

# Android sparse image -> raw
unsparse() {
  if [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
    echo "$1 is an Android sparse image, converting"
    simg2img "$1" "$1.raw" && mv -f "$1.raw" "$1"
  fi
}

# the root filesystem as a bare ext4 image
ROOT=$(ls /tmp/pmos-export/*-root.img 2>/dev/null | head -n1 || true)
if [ -n "$ROOT" ]; then
  cp -L "$ROOT" work/pmos-root.img
  unsparse work/pmos-root.img
else
  echo "WARN: no separate root image exported, cutting the root partition out of the full image"
  FULL="/tmp/pmos-export/${DEVICE}.img"
  [ -e "$FULL" ] || { echo "ERROR: no root image and no full image exported"; exit 1; }
  cp -L "$FULL" work/pmos-full.img
  unsparse work/pmos-full.img
  sfdisk -d work/pmos-full.img
  read -r START SIZE < <(sfdisk -d work/pmos-full.img | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\).*/\1 \2/p' | tail -n1)
  [ -n "${START:-}" ] && [ -n "${SIZE:-}" ] || { echo "ERROR: cannot read the partition table of the full image"; exit 1; }
  dd if=work/pmos-full.img of=work/pmos-root.img bs=512 skip="$START" count="$SIZE"
  rm -f work/pmos-full.img
fi
chmod u+rw work/pmos-root.img out/boot.img

# the installer and the initramfs find the root by its label
LABEL=$(e2label work/pmos-root.img) || { echo "ERROR: the root image is not an ext2/3/4 filesystem"; exit 1; }
echo "root label: '$LABEL'"
[ "$LABEL" = pmOS_root ] || e2label work/pmos-root.img pmOS_root
ls -la out work
