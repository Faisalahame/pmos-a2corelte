#!/usr/bin/env bash
# Prepares the pmOS root image for the way the Galaxy A2 Core boots it (run as root):
#   * ext4 features TWRP's old 3.18 kernel cannot read are switched off (metadata_csum_seed, metadata_csum),
#     so the root can be mounted from TWRP to read the diagnostics log
#   * our tiny initramfs mounts the root itself, so /etc/fstab must not ask for /boot or a root label
#   * first boot grows the filesystem to the whole USERDATA partition (resize2fs, online)
#   * sshd is switched on, and NetworkManager leaves the USB network (usb0) alone
#   * a boot diagnostics log is written to /var/log/pmos-diag.txt (readable from TWRP, no PC or SSH needed)
#   * touchscreen: the first probe of the Synaptics RMI4 chip fails at boot ("RMI initial reset failed",
#     then a duplicate rmi4-00.fn34), so ~30 s after boot the driver is re-probed with debug output on
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
# 1) ~30 s after boot: if no touchscreen input device exists, re-probe the Synaptics RMI4 driver
#    (3 tries, with dynamic debug on so the log shows what the chip answers). If a re-probe works,
#    touch simply starts working.
# 2) Saves boot diagnostics to /var/log/pmos-diag.txt so they can be read from TWRP.
OUT=/var/log/pmos-diag.txt
TOUT=/var/log/pmos-touch-debug.txt
DEV=3-004b
DRV=/sys/bus/i2c/drivers/rmi4_i2c

have_touch() { grep -qiE 'synaptics|rmi' /proc/bus/input/devices; }

touch_debug() {
  {
    echo "== touch re-probe at $(date), uptime $(cut -d' ' -f1 /proc/uptime) s"
    if have_touch; then echo "touchscreen input device already present, nothing to do"; return 0; fi
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
    DYN=/sys/kernel/debug/dynamic_debug/control
    if [ -w "$DYN" ]; then
      echo 'module rmi_core +p' > "$DYN"
      echo 'module rmi_i2c +p' > "$DYN"
      echo "dynamic debug enabled for rmi_core / rmi_i2c"
    else
      echo "(no dynamic_debug control file, CONFIG_DYNAMIC_DEBUG or debugfs missing)"
    fi
    n=1
    while [ $n -le 3 ]; do
      echo "-- try $n: unbind/bind $DEV"
      echo "== MARK touch reprobe try $n" > /dev/kmsg
      [ -e "$DRV/$DEV" ] && echo "$DEV" > "$DRV/unbind"
      sleep 1
      echo "$DEV" > "$DRV/bind"
      sleep 4
      dmesg | sed -n "/MARK touch reprobe try $n/,\$p" | head -n 120
      if have_touch; then echo "-- touchscreen input device appeared after try $n"; return 0; fi
      n=$((n+1))
      sleep 6
    done
    echo "-- unbind/bind did not help, reloading the modules"
    echo "== MARK touch module reload" > /dev/kmsg
    modprobe -r rmi_i2c rmi_core 2>&1
    sleep 1
    modprobe rmi_i2c 2>&1
    sleep 5
    dmesg | sed -n '/MARK touch module reload/,$p' | head -n 120
    if have_touch; then echo "-- touchscreen input device appeared after the module reload"; else echo "-- still no touchscreen input device"; fi
  } > "$TOUT" 2>&1
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
    echo "== kernel config"; zcat /proc/config.gz 2>/dev/null | grep -E 'RMI4|INPUT_TOUCHSCREEN|DYNAMIC_DEBUG' || echo "(no /proc/config.gz)"
    echo "== touch re-probe log ($TOUT)"; cat "$TOUT" 2>&1
    echo "== dmesg (full)"; dmesg
  } > "$OUT.tmp" 2>&1
  mv -f "$OUT.tmp" "$OUT"
  sync
}

sleep 30; touch_debug
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
