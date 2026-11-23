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
# TOUCHSCREEN: the kernel is built FROM SOURCE with small touchscreen changes (see "touchscreen" below).
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
# i2c-tools: i2ctransfer, used by the boot diagnostics to read the touchscreen chip's registers raw
EXTRA_PKGS="openssh,e2fsprogs-extra,nano,i2c-tools"

WORK="$HOME/.local/var/pmbootstrap"
PMAPORTS="$WORK/cache_git/pmaports"

# On any failure print the interesting lines of pmbootstrap's own log
on_err() {
  set +x
  echo "== pmbootstrap log: error lines =="
  grep -aiE 'error|unable to select|no such package|required by|conflict|not found|failed|satisf|breaks' "$WORK/log.txt" 2>/dev/null \
    | grep -av 'APKINDEX\|Unable to find\|Error relocating' | tail -n 30 | cut -c1-300 | tee work/pmb-errors.log || true
  # kernel build logs (the touchscreen patch runs in the kernel package's prepare step)
  grep -aE 'pmos-a2corelte touch|\*\*\*|error:|Error [0-9]|ERROR \(' "$WORK/log.txt" 2>/dev/null | tail -n 40 | cut -c1-300 | tee work/pmb-kernel-errors.log || true
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
# OpenRC from the start. With the default (systemd) service manager "pmbootstrap install" died in every run while it
# built the systemd package, and the old fallback ("zap -p") then DELETED the kernel package we had just built, so the
# rootfs got the mirror's kernel (6.15-r6) and none of the touchscreen changes (run of 15:28).
pmbootstrap -y config service_manager openrc \
  || pmbootstrap -y config systemd never \
  || echo "WARN: neither 'service_manager openrc' nor 'systemd never' was accepted by this pmbootstrap"
pmbootstrap config | grep -iE 'service_manager|systemd' || true

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
# kernel's RMI4 driver (devicetree: syna,rmi4-i2c). The stock (TWRP) driver never resets the chip and works fine with it
# (TWRP log: "Device status[0x81] status.code[1]", F12 and F51 found, product ID TD4101).
# On postmarketOS (6.15 mainline RMI4 core) the probe dies in rmi_create_function(): the chip's PDT lists F34 twice, the
# second one fails with -EEXIST ("sysfs: cannot create duplicate filename .../rmi4-01.fn34") and no touch input device
# is created. Changes, all made at the END of prepare() of the kernel package:
#   1. devicetree: syna,startup-delay-ms / syna,reset-delay-ms = 500 ms on the touchscreen node
#      (the stock devicetree ALREADY has both properties, so the old lines are removed first, otherwise dtc fails
#      with "Duplicate property name")
#   2. rmi_driver.c: no initial reset command (just a 500 ms wait), like the stock Samsung driver
#   3. rmi_driver.c, rmi_create_function(): a PDT entry whose function number was already created is skipped, and every
#      PDT entry is logged with dev_info (this kernel has no dynamic debug), so dmesg shows what the chip lists
#   4. rmi_i2c.c: THE REAL FIX (see "rmi_i2c.c" below): page select + register access in ONE i2c transfer, like the
#      stock driver. Without it every page reads the same table.
# (the devicetree sources are only copied into the kernel tree at the end of prepare().)
# Run of 17:52 (commit 77351b4): the duplicate skip works, but the chip's table lists only F34, F1B and F04 (the same three
# entries on pages 0 to 12) and no F01/F12, so the probe stops with "Missing F01 container". The stock driver reads F12/F51
# fine on the same bus. Cause: mainline sends the page select (0xff) as its own i2c transaction, which the TD4101 ignores;
# the stock driver sends [0xff,page] + [reg] + read as one transfer with repeated starts. That is change 4.
# The boot diagnostics also read the chip's registers raw with i2ctransfer (i2c-tools) and the kernel gets
# CONFIG_I2C_CHARDEV (/dev/i2c-3).
KDIR=$(find "$PMAPORTS" -maxdepth 4 -type d -name linux-postmarketos-exynos7870 | head -n1 || true)
KCFG=""
if [ -n "$KDIR" ]; then
  KCFG=$(ls "$KDIR"/config-*.aarch64 2>/dev/null | head -n1 || true)
fi
if [ -n "$KCFG" ]; then
  echo "===== kernel config: $KCFG ====="
  grep -E 'RMI4|INPUT_TOUCHSCREEN|^CONFIG_I2C=|I2C_S3C|I2C_EXYNOS' "$KCFG" | tee work/kernel-touch-config.log || true
  # TEST BUILD (timing): the RMI4 touch driver is built INTO the kernel (=y) instead of a module. As a module it is loaded
  # by userspace at about 5.9 s and first reads the chip at 6.4 s (chip already answers with a fixed byte stream, with or
  # without the driver loaded); Samsung's driver first reads the chip at about 3.5 s and gets a normal register map.
  # Built in, the first read happens right after the I2C bus comes up (about 2.3 s), so the "PDT at 0x00e9" line in dmesg
  # shows whether the chip is in register mode that early.
  for o in INPUT_TOUCHSCREEN RMI4_CORE RMI4_I2C RMI4_F01 RMI4_F11 RMI4_F12; do
    sed -i "/^CONFIG_${o}=/d;/^# CONFIG_${o} is not set/d" "$KCFG"
  done
  echo >> "$KCFG"
  printf '%s\n' CONFIG_INPUT_TOUCHSCREEN=y CONFIG_RMI4_CORE=y CONFIG_RMI4_I2C=y CONFIG_RMI4_F01=y CONFIG_RMI4_F11=y CONFIG_RMI4_F12=y >> "$KCFG"
  grep -E 'RMI4|INPUT_TOUCHSCREEN' "$KCFG" | tee -a work/kernel-touch-config.log || true
  # /dev/i2c-N, so the boot diagnostics can read the touchscreen chip raw with i2ctransfer
  if ! grep -qE '^CONFIG_I2C_CHARDEV=[ym]' "$KCFG"; then
    sed -i '/^CONFIG_I2C_CHARDEV=/d;/^# CONFIG_I2C_CHARDEV is not set/d' "$KCFG"
    printf '\nCONFIG_I2C_CHARDEV=y\n' >> "$KCFG"
  fi
  grep -E 'I2C_CHARDEV' "$KCFG" | tee -a work/kernel-touch-config.log || true
else
  echo "WARN: kernel config of linux-postmarketos-exynos7870 not found in pmaports"
fi

if [ -z "$KDIR" ] || [ ! -f "$KDIR/APKBUILD" ]; then
  echo "ERROR: linux-postmarketos-exynos7870 is not in pmaports, cannot apply the touchscreen fix"
  exit 1
fi
echo "===== kernel APKBUILD (before the touchscreen patch) ====="; cat "$KDIR/APKBUILD"

# the block that goes at the end of prepare() (runs in the kernel source directory, Alpine ash)
cat > work/touch-inject.sh <<'EOS'
	# ---- pmos-a2corelte touch fix begin ----
	_touch_dts=$(grep -rl 'syna,rmi4-i2c' arch/arm64/boot/dts/exynos/ | grep -v Makefile || true)
	[ -n "$_touch_dts" ] || { echo "pmos-a2corelte touch fix: ERROR no touchscreen node in the devicetrees"; return 1; }
	for _f in $_touch_dts; do
		echo "pmos-a2corelte touch fix: touchscreen lines BEFORE in $_f:"
		grep -n 'syna,' "$_f" || true
		sed -i '/syna,startup-delay-ms/d;/syna,reset-delay-ms/d' "$_f"
		awk '{ print } /compatible = "syna,rmi4-i2c";/ { print "\t\tsyna,startup-delay-ms = <500>;"; print "\t\tsyna,reset-delay-ms = <500>;" }' "$_f" > "$_f.new" && mv "$_f.new" "$_f"
		echo "pmos-a2corelte touch fix: devicetree patched: $_f"
		grep -n 'syna,' "$_f"
		[ "$(grep -c 'syna,startup-delay-ms' "$_f")" = 1 ] || { echo "pmos-a2corelte touch fix: ERROR startup-delay is not exactly once in $_f"; return 1; }
		[ "$(grep -c 'syna,reset-delay-ms' "$_f")" = 1 ] || { echo "pmos-a2corelte touch fix: ERROR reset-delay is not exactly once in $_f"; return 1; }
	done
	_touch_rd=drivers/input/rmi4/rmi_driver.c
	grep -q 'rmi_scan_pdt(rmi_dev, NULL, rmi_initial_reset)' "$_touch_rd" || { echo "pmos-a2corelte touch fix: ERROR rmi_initial_reset call not found in $_touch_rd"; return 1; }
	sed -i 's|retval = rmi_scan_pdt(rmi_dev, NULL, rmi_initial_reset);|msleep(500); retval = 0; /* pmos-a2corelte: no initial reset, like the stock driver */|' "$_touch_rd"
	grep -q '<linux/delay.h>' "$_touch_rd" || sed -i '0,/#include <linux\/module.h>/s||#include <linux/module.h>\n#include <linux/delay.h>|' "$_touch_rd"
	# rmi_create_function(): log every PDT entry and skip a function number that already exists (F34 is listed twice)
	grep -qF 'fn = kzalloc(sizeof(struct rmi_function) +' "$_touch_rd" || { echo "pmos-a2corelte touch fix: ERROR rmi_create_function anchor not found in $_touch_rd"; return 1; }
	cat > "$srcdir/pmos-dedupe.inc" <<-'EOC'
		{
		static int pm_log;
		struct rmi_driver_data *pm_data = dev_get_drvdata(&rmi_dev->dev);
		struct rmi_function *pm_old;
		bool pm_dup = false;
		list_for_each_entry(pm_old, &pm_data->function_list, node)
			if (pm_old->fd.function_number == pdt->function_number)
				pm_dup = true;
		if (pm_log++ < 40)
			dev_info(&rmi_dev->dev, "pmos-a2corelte PDT: F%02X v%u page 0x%04x query 0x%02x cmd 0x%02x ctrl 0x%02x data 0x%02x irqs %u%s\n", pdt->function_number, pdt->function_version, pdt->page_start, pdt->query_base_addr, pdt->command_base_addr, pdt->control_base_addr, pdt->data_base_addr, pdt->interrupt_source_count, pm_dup ? " (duplicate, skipped)" : "");
		if (pm_dup)
			return RMI_SCAN_CONTINUE;
		}
	EOC
	awk -v f="$srcdir/pmos-dedupe.inc" 'index($0, "fn = kzalloc(sizeof(struct rmi_function) +") && !d { while ((getline l < f) > 0) print l; close(f); d=1 } { print }' "$_touch_rd" > "$_touch_rd.new" && mv "$_touch_rd.new" "$_touch_rd"
	grep -q 'pmos-a2corelte PDT' "$_touch_rd" || { echo "pmos-a2corelte touch fix: ERROR the PDT block was not inserted into $_touch_rd"; return 1; }
	grep -n 'pmos-a2corelte\|linux/delay.h' "$_touch_rd"
	# ---- pmos-a2corelte touch fix end ----
EOS

# ---- rmi_i2c.c: page select + access in ONE i2c transfer (change 4, the real fix for the missing F01) ----
# Patch against the 6.15 drivers/input/rmi4/rmi_i2c.c, embedded as gzip+base64 (plain ASCII: no tab/space problems).
# It is unpacked here, checked against its sha256, and the same text goes into prepare() where it is applied with patch -p1.
# If it does not apply, prepare() fails within the first minutes of the kernel build (no 30 minute wait).
RMI_I2C_PATCH_SHA=18788d7b2196a310afda9a87d5152ec07d9e9e56ec3dabad5e11bc3a9b92ad65
RMI_I2C_PATCH_B64='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'
printf '%s' "$RMI_I2C_PATCH_B64" | base64 -d | gunzip > work/rmi-i2c.patch
echo "$RMI_I2C_PATCH_SHA  work/rmi-i2c.patch" | sha256sum -c -
{
  printf '\t# rmi_i2c.c: page select + register access in ONE i2c transfer, like the stock Samsung driver\n'
  printf "\techo '%s' | base64 -d | gunzip > \"\$srcdir/pmos-rmi-i2c.patch\"\n" "$RMI_I2C_PATCH_B64"
  printf '\tpatch -p1 -i "$srcdir/pmos-rmi-i2c.patch" || { echo "pmos-a2corelte touch fix: ERROR the rmi_i2c.c patch did not apply"; return 1; }\n'
  printf '\tgrep -q RMI_I2C_RETRIES drivers/input/rmi4/rmi_i2c.c || { echo "pmos-a2corelte touch fix: ERROR rmi_i2c.c was not patched"; return 1; }\n'
  printf '\techo "pmos-a2corelte touch fix: rmi_i2c.c patched (combined page select)"\n'
} > work/touch-inject-i2c.sh
awk -v f=work/touch-inject-i2c.sh '/# ---- pmos-a2corelte touch fix end ----/ { while ((getline l < f) > 0) print l; close(f) } { print }' work/touch-inject.sh > work/touch-inject.sh.new \
  && mv work/touch-inject.sh.new work/touch-inject.sh
grep -c 'RMI_I2C_RETRIES' work/touch-inject.sh

if grep -q 'pmos-a2corelte touch fix begin' "$KDIR/APKBUILD"; then
  echo "touchscreen patch already in the kernel APKBUILD"
elif grep -q '^prepare()' "$KDIR/APKBUILD"; then
  # put the block in front of the closing brace of prepare()
  awk -v f=work/touch-inject.sh '/^prepare\(\)/ { inp=1 } inp && /^}$/ { while ((getline l < f) > 0) print l; close(f); inp=0 } { print }' \
    "$KDIR/APKBUILD" > work/APKBUILD.kernel.new
  cp work/APKBUILD.kernel.new "$KDIR/APKBUILD"
else
  { printf '\nprepare() {\n\tdefault_prepare\n'; cat work/touch-inject.sh; printf '}\n'; } >> "$KDIR/APKBUILD"
fi
grep -q 'pmos-a2corelte touch fix begin' "$KDIR/APKBUILD" || { echo "ERROR: could not insert the touchscreen patch into the kernel APKBUILD"; exit 1; }
# build the kernel from source instead of using the mirror's binary
sed -i 's/^pkgrel=.*/pkgrel=99/' "$KDIR/APKBUILD"
pmbootstrap -y checksum linux-postmarketos-exynos7870
echo "===== kernel prepare() after the touchscreen patch ====="
sed -n '/^prepare()/,/^}/p' "$KDIR/APKBUILD" | cut -c1-300

pmbootstrap config || true

# Build the patched kernel package explicitly: "pmbootstrap install" only builds the device package and
# would take the mirror's kernel binary (an earlier run did exactly that: 8 minutes, no kernel build).
# The build takes about 25 minutes. The result is kernel 6.15 pkgrel 99 ("uname -a" on the phone shows #100-postmarketOS).
pmbootstrap -y build --arch aarch64 --force linux-postmarketos-exynos7870
grep -aE 'pmos-a2corelte touch fix' "$WORK/log.txt" 2>/dev/null | tail -n 30 | tee work/kernel-touch-patch.log || true
ls -la "$WORK"/packages/edge/aarch64/ 2>/dev/null | grep -i linux-postmarketos || true
[ -s "$WORK"/packages/edge/aarch64/linux-postmarketos-exynos7870-6.15-r99.apk ] \
  || { echo "ERROR: the patched kernel package linux-postmarketos-exynos7870-6.15-r99.apk was not built"; exit 1; }

# --split: boot and root as two separate images (we only use the bare root filesystem).
# NO "pmbootstrap zap -p" here: it deletes the locally built packages, i.e. the kernel built above.
pmbootstrap -y install --split --password "$PMOS_PASS" \
  || { cp -f "$WORK/log.txt" work/pmb-install-attempt.log 2>/dev/null || true; false; }

CH="$WORK/chroot_rootfs_$DEVICE"
echo "== rootfs /boot =="
sudo ls -la "$CH/boot" || true

# which kernel is really in the rootfs (must be our own r99 build with the touchscreen patch)
echo "== kernel package in the rootfs =="
sudo cat "$CH"/usr/share/kernel/postmarketos-exynos7870/kernel.release 2>/dev/null | tee work/kernel-release.log || true
sudo ls "$CH"/usr/lib/apk/db 2>/dev/null | head -n 3 || true
sudo grep -A1 '^P:linux-postmarketos-exynos7870$' "$CH"/lib/apk/db/installed 2>/dev/null | tee -a work/kernel-release.log || true
KV=$(sudo grep -A1 '^P:linux-postmarketos-exynos7870$' "$CH"/lib/apk/db/installed 2>/dev/null | sed -n 's/^V://p' | head -n1 || true)
echo "kernel package version in the rootfs: '$KV'"
[ "$KV" = "6.15-r99" ] || { echo "ERROR: the rootfs has linux-postmarketos-exynos7870 '$KV' and not our own 6.15-r99 build with the touchscreen patch"; exit 1; }

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
