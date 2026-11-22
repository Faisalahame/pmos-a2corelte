#!/usr/bin/env bash
# Prepares the pmOS root image for the way the Galaxy A2 Core boots it (run as root):
#   * ext4 features TWRP's old 3.18 kernel cannot read are switched off (metadata_csum_seed, metadata_csum),
#     so the root can be mounted from TWRP to read the diagnostics log
#   * our tiny initramfs mounts the root itself, so /etc/fstab must not ask for /boot or a root label
#   * first boot grows the filesystem to the whole USERDATA partition (resize2fs, online)
#   * sshd is switched on, and NetworkManager leaves the USB network (usb0) alone
#   * a boot diagnostics log is written to /var/log/pmos-diag.txt (readable from TWRP, no PC or SSH needed)
#   * touchscreen: if the first probe of the Synaptics RMI4 chip fails at boot, ~30 s after boot the driver is
#     re-probed (the kernel logs every PDT entry the chip lists, "pmos-a2corelte PDT"), and then the chip's
#     registers are read raw with i2ctransfer (section "raw i2c test" at the end of /var/log/pmos-touch-debug.txt)
#   * at the very end scripts/setup-wifi-ssh.sh runs: the phone joins the mobile hotspot "faisal" on boot (SSH from Termux)
# usage: sudo bash scripts/fixup-rootfs.sh work/pmos-root.img
set -euxo pipefail
IMG="${1:?usage: fixup-rootfs.sh root.img}"
M=$(mktemp -d)
cleanup() { mountpoint -q "$M" && umount "$M"; rmdir "$M" 2>/dev/null || true; }
trap cleanup EXIT

e2fsck -fy "$IMG" || [ $? -le 1 ]

# ---- ext4 features for TWRP's old kernel ----
# TWRP on this phone refuses the pmbootstrap image: "unsupported optional features (2000)" = metadata_csum_seed.
# metadata_csum is switched off too: the old kernel can corrupt a filesystem that has it (seen with the Kali image).
echo "== ext4 features before =="; dumpe2fs -h "$IMG" 2>/dev/null | grep -i '^Filesystem features' || true
tune2fs -O ^metadata_csum_seed "$IMG" || echo "WARN: could not clear metadata_csum_seed"
tune2fs -O ^metadata_csum "$IMG" || echo "WARN: could not clear metadata_csum"
e2fsck -fyD "$IMG" || [ $? -le 1 ]
echo "== ext4 features after =="; dumpe2fs -h "$IMG" 2>/dev/null | grep -i '^Filesystem features'
if dumpe2fs -h "$IMG" 2>/dev/null | grep -i '^Filesystem features' | grep -q 'metadata_csum_seed'; then
  echo "ERROR: metadata_csum_seed is still set, TWRP will not be able to mount the root"
  exit 1
fi

mount -o loop,rw "$IMG" "$M"

echo "== init system in the image =="
ls -la "$M/sbin/init" || true
ls -d "$M/usr/lib/systemd/system" "$M/lib/systemd/system" "$M/etc/init.d" 2>/dev/null || true
ls "$M/usr/sbin/resize2fs" "$M/sbin/resize2fs" 2>/dev/null || echo "WARN: resize2fs not in the image, the filesystem will not grow by itself"
echo "== touchscreen modules in the image =="
ls "$M"/lib/modules/*/kernel/drivers/input/rmi4 2>&1 || echo "(no rmi4 modules on disk: built into the kernel, or missing)"
echo "== i2c-tools in the image =="
ls "$M"/usr/bin/i2ctransfer "$M"/usr/sbin/i2ctransfer 2>&1 || echo "WARN: i2ctransfer is not in the image, the raw i2c test will be skipped"

# ---- fstab ----
cat > "$M/etc/fstab" <<'EOF'
# The initramfs mounts the root filesystem (the USERDATA partition) before init starts.
# There is no separate /boot partition on this phone: the boot image is in the BOOT partition.
EOF

# ---- first-boot filesystem grow ----
install -d "$M/usr/local/sbin" "$M/var/lib" "$M/var/log"
cat > "$M/usr/local/sbin/pmos-growfs" <<'EOF'
#!/bin/sh
# Grow the root filesystem to the whole partition, once (first boot).
DONE=/var/lib/pmos-growfs.done
[ -e "$DONE" ] && exit 0
DEV=$(awk '$2=="/" && $1 ~ /^\/dev\// {d=$1} END{print d}' /proc/mounts)
[ -b "$DEV" ] || exit 0
command -v resize2fs >/dev/null 2>&1 || exit 0
if resize2fs "$DEV"; then touch "$DONE"; fi
exit 0
EOF
chmod 755 "$M/usr/local/sbin/pmos-growfs"

# ---- boot diagnostics + touchscreen re-probe ----
cat > "$M/usr/local/sbin/pmos-diag" <<'EOF'
#!/bin/sh
# 1) ~25 s after boot: first snapshot (so something is on disk even if the phone is rebooted early)
# 2) ~30 s after boot: if no touchscreen input device exists, re-probe the Synaptics RMI4 driver (3 tries)
#    and log what the kernel says. If a re-probe works, touch simply starts working.
# 3) then read the touchscreen chip's registers raw (i2ctransfer on /dev/i2c-3), several access patterns
# 4) Saves boot diagnostics to /var/log/pmos-diag.txt so they can be read from TWRP.
#    The whole run takes about 3 minutes: wait for it before rebooting to TWRP.
OUT=/var/log/pmos-diag.txt
TOUT=/var/log/pmos-touch-debug.txt
DEV=3-004b
DRV=/sys/bus/i2c/drivers/rmi4_i2c

have_touch() { grep -qiE 'synaptics|rmi' /proc/bus/input/devices; }

touch_debug() {
  {
    echo "== touch re-probe at $(date), uptime $(cut -d' ' -f1 /proc/uptime) s"
    if have_touch; then echo "touchscreen input device already present, nothing to do"; return 0; fi
    n=1
    while [ $n -le 3 ]; do
      echo "-- try $n: unbind/bind $DEV"
      echo "== MARK touch reprobe try $n" > /dev/kmsg
      [ -e "$DRV/$DEV" ] && echo "$DEV" > "$DRV/unbind"
      sleep 1
      echo "$DEV" > "$DRV/bind"
      sleep 4
      dmesg | sed -n "/MARK touch reprobe try $n/,\$p" | grep -v '^\[[ 0-9.]*\]  ' | head -n 60
      sync
      if have_touch; then echo "-- touchscreen input device appeared after try $n"; sync; return 0; fi
      n=$((n+1))
      sleep 6
    done
    echo "-- unbind/bind did not help, reloading the modules"
    echo "== MARK touch module reload" > /dev/kmsg
    modprobe -r rmi_i2c rmi_core 2>&1
    sleep 1
    modprobe rmi_i2c 2>&1
    sleep 5
    dmesg | sed -n '/MARK touch module reload/,$p' | grep -v '^\[[ 0-9.]*\]  ' | head -n 60
    if have_touch; then echo "-- touchscreen input device appeared after the module reload"; else echo "-- still no touchscreen input device"; fi
  } > "$TOUT" 2>&1
  sync
}

# Raw register reads of the chip at 0x4b on /dev/i2c-3 (the RMI4 driver is unbound first). The stock Samsung driver sees
# F12/F51 and a product ID TD4101 on this same bus, the mainline driver only gets F34/F1B/F04. This shows what the chip
# returns for different access patterns. i2ctransfer prints the bytes it read as 0x.. 0x.. (an error text if it failed).
raw_i2c() {
  command -v i2ctransfer >/dev/null 2>&1 || { echo "(no i2ctransfer binary, raw test skipped)" >> "$TOUT"; return 0; }
  {
    echo
    echo "== raw i2c test at $(date), uptime $(cut -d' ' -f1 /proc/uptime) s"
    modprobe i2c-dev 2>&1 || true
    ls -la /dev/i2c-* 2>&1 || true
    [ -e "$DRV/$DEV" ] && echo "$DEV" > "$DRV/unbind"
    sleep 1
    T="i2ctransfer -f -y 3"
    A=0x4b
    echo "-- page select register 0xff:"; $T w1@$A 0xff r1@$A 2>&1
    for p in 0x00 0x01 0x02 0x03; do
      echo "-- select page $p (write 0xff $p), then PDT entries: 6 bytes at 0xe9, 0xe3, 0xdd, ... (write address + read, repeated start)"
      $T w2@$A 0xff $p 2>&1
      printf '   page select reads back: '; $T w1@$A 0xff r1@$A 2>&1
      for o in 0xe9 0xe3 0xdd 0xd7 0xd1 0xcb 0xc5; do printf '   %s: ' $o; $T w1@$A $o r6@$A 2>&1; done
      printf '   one 42-byte read 0xc5..0xee: '; $T w1@$A 0xc5 r42@$A 2>&1
    done
    echo "-- page 0, address write and read as two separate transactions"
    $T w2@$A 0xff 0x00 2>&1
    for o in 0xe9 0xe3 0xdd; do printf '   %s: ' $o; $T w1@$A $o 2>&1; $T r6@$A 2>&1; done
    echo "-- page 0, 0xe9..0xee one byte per transaction"
    for i in 0 1 2 3 4 5; do o=$(printf '0x%02x' $((0xe9 + i))); printf '   %s: ' $o; $T w1@$A $o r1@$A 2>&1; done
    echo "-- page 0, first 64 bytes from 0x00"
    $T w1@$A 0x00 r64@$A 2>&1
    echo "-- read without an address write (where the chip's read pointer is)"
    $T r12@$A 2>&1
    echo "== raw i2c test done at $(date)"
  } >> "$TOUT" 2>&1
  sync
}

snap() {
  {
    echo "== pmos-diag at $(date), uptime $(cut -d' ' -f1 /proc/uptime) s"
    uname -a
    echo "== input devices"; cat /proc/bus/input/devices
    echo "== touch / rmi / i2c lines of dmesg"; dmesg | grep -iE 'rmi|synap|touch|i2c|input'
    echo "== loaded modules"; lsmod
    echo "== i2c devices"
    for d in /sys/bus/i2c/devices/*; do
      [ -e "$d" ] || continue
      echo "$d name=$(cat "$d/name" 2>/dev/null) driver=$(readlink "$d/driver" 2>/dev/null)"
    done
    echo "== rmi modules on disk"; ls /lib/modules/*/kernel/drivers/input/rmi4 2>&1
    echo "== kernel config"; zcat /proc/config.gz 2>/dev/null | grep -E 'RMI4|INPUT_TOUCHSCREEN|DYNAMIC_DEBUG|I2C_CHARDEV' || echo "(no /proc/config.gz)"
    echo "== touch re-probe log ($TOUT)"; cat "$TOUT" 2>&1
    echo "== dmesg (full)"; dmesg
  } > "$OUT.tmp" 2>&1
  mv -f "$OUT.tmp" "$OUT"
  sync
}

sleep 25; snap
sleep 5; touch_debug
raw_i2c
snap
sleep 90; snap
exit 0
EOF
chmod 755 "$M/usr/local/sbin/pmos-diag"

# OpenRC
if [ -d "$M/etc/init.d" ]; then
  cat > "$M/etc/init.d/pmos-growfs" <<'EOF'
#!/sbin/openrc-run
description="Grow the root filesystem to the whole partition (first boot only)"
depend() {
	need localmount
	after bootmisc
}
start() {
	ebegin "Growing the root filesystem"
	/usr/local/sbin/pmos-growfs
	eend 0
}
EOF
  chmod 755 "$M/etc/init.d/pmos-growfs"
  cat > "$M/etc/init.d/pmos-diag" <<'EOF'
#!/sbin/openrc-run
description="Touchscreen re-probe and boot diagnostics (/var/log/pmos-diag.txt)"
depend() {
	need localmount
}
start() {
	ebegin "Saving boot diagnostics"
	start-stop-daemon --start --background --exec /usr/local/sbin/pmos-diag
	eend 0
}
EOF
  chmod 755 "$M/etc/init.d/pmos-diag"
  mkdir -p "$M/etc/runlevels/default"
  ln -sf /etc/init.d/pmos-growfs "$M/etc/runlevels/default/pmos-growfs"
  ln -sf /etc/init.d/pmos-diag "$M/etc/runlevels/default/pmos-diag"
  # sshd
  if [ -e "$M/etc/init.d/sshd" ]; then
    ln -sf /etc/init.d/sshd "$M/etc/runlevels/default/sshd"
  fi
fi

# systemd
SD=""
for d in usr/lib/systemd/system lib/systemd/system; do
  [ -d "$M/$d" ] && SD="$d" && break
done
if [ -n "$SD" ]; then
  mkdir -p "$M/etc/systemd/system/multi-user.target.wants"
  cat > "$M/etc/systemd/system/pmos-growfs.service" <<'EOF'
[Unit]
Description=Grow the root filesystem to the whole partition (first boot only)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pmos-growfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  cat > "$M/etc/systemd/system/pmos-diag.service" <<'EOF'
[Unit]
Description=Touchscreen re-probe and boot diagnostics (/var/log/pmos-diag.txt)
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/pmos-diag

[Install]
WantedBy=multi-user.target
EOF
  ln -sf /etc/systemd/system/pmos-growfs.service "$M/etc/systemd/system/multi-user.target.wants/pmos-growfs.service"
  ln -sf /etc/systemd/system/pmos-diag.service "$M/etc/systemd/system/multi-user.target.wants/pmos-diag.service"
  for u in sshd.service ssh.service; do
    if [ -e "$M/$SD/$u" ]; then
      ln -sf "/$SD/$u" "$M/etc/systemd/system/multi-user.target.wants/$u"
    fi
  done
fi

# ---- USB network: the initramfs gives usb0 172.16.42.1, NetworkManager must not reset it ----
mkdir -p "$M/etc/NetworkManager/conf.d"
cat > "$M/etc/NetworkManager/conf.d/10-pmos-usb0.conf" <<'EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
EOF

sync
umount "$M"
e2fsck -fn "$IMG"
echo "fixup done"

# ---- Wi-Fi: join the mobile hotspot "faisal" on boot + sshd (own script, mounts the image again) ----
bash "$(dirname "$0")/setup-wifi-ssh.sh" "$IMG"
