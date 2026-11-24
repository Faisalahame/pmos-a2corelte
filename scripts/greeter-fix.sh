#!/usr/bin/env bash
# display-6.19 branch only (hooked in by scripts/apply-greeter-fix.py, runs at the end of fixup-rootfs.sh).
#
# Problem: on 6.19 the display (exynos-drm) only exists ~18 s after boot (it waits out the deferred-probe timeout), but
# greetd starts its greeter (phrog on phoc) at ~14 s. The greeter starts with no screen, never recovers, and the phone
# stays on the boot splash (spinning circle). dmesg showed exactly one greeter session for the next 160 s, so restarting
# greetd (supervise-daemon) never happened.
# Fix: an OpenRC service that waits until the DSI connector exists, ordered BEFORE the greeter service.
#
# Also fixes the touch diagnostics for 6.19: on 6.15 the touch chip was 3-004b on /dev/i2c-3, on 6.19 it is 2-004b on
# i2c-2, so every re-probe in pmos-diag said "No such device". The bus is now looked up at run time. pmos-diag also logs
# ps, rc-status, /dev/dri and the greetd config from now on.
# usage: sudo bash scripts/greeter-fix.sh work/pmos-root.img
set -euxo pipefail
IMG="${1:?usage: greeter-fix.sh root.img}"
M=$(mktemp -d)
cleanup() { mountpoint -q "$M" && umount "$M"; rmdir "$M" 2>/dev/null || true; }
trap cleanup EXIT
mount -o loop,rw "$IMG" "$M"

echo "== greeter / login services in the image =="
ls -la "$M"/etc/init.d | grep -iE 'greet|tinydm|seatd|elogind|dbus' || true
ls -la "$M"/etc/runlevels/*/ 2>/dev/null | grep -iE 'greet|tinydm|seatd|elogind' || true
cat "$M/etc/greetd/config.toml" 2>/dev/null || echo "(no /etc/greetd/config.toml)"
cat "$M"/etc/conf.d/*greetd* 2>/dev/null || true

# ---- service: wait for the display ----
cat > "$M/etc/init.d/pmos-wait-display" <<'EOF'
#!/sbin/openrc-run
description="Wait for the display (exynos-drm) before the greeter starts"
depend() {
	need localmount
	before greetd user.greetd tinydm
}
start() {
	ebegin "Waiting for the display"
	i=0
	while [ $i -lt 90 ]; do
		ls /sys/class/drm/card*-DSI-* >/dev/null 2>&1 && break
		sleep 1
		i=$((i+1))
	done
	udevadm settle -t 5 2>/dev/null
	sleep 2
	echo "pmos-wait-display: waited ${i} s" > /dev/kmsg 2>/dev/null
	eend 0
}
EOF
chmod 755 "$M/etc/init.d/pmos-wait-display"
mkdir -p "$M/etc/runlevels/default"
ln -sf /etc/init.d/pmos-wait-display "$M/etc/runlevels/default/pmos-wait-display"
# same runlevel as the greeter service, if that is not "default"
for l in "$M"/etc/runlevels/*/*greetd* "$M"/etc/runlevels/*/tinydm; do
  if [ -e "$l" ] || [ -L "$l" ]; then
    ln -sf /etc/init.d/pmos-wait-display "$(dirname "$l")/pmos-wait-display"
  fi
done
ls -la "$M"/etc/runlevels/*/pmos-wait-display

# ---- pmos-diag: touch bus looked up at run time (6.15: 3-004b, 6.19: 2-004b) + more logging ----
D="$M/usr/local/sbin/pmos-diag"
if [ -f "$D" ]; then
  python3 - "$D" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
def rep(old, new):
    global t
    if old in t:
        t = t.replace(old, new, 1)
    else:
        print("WARN greeter-fix: anchor not found in pmos-diag: %r" % old)
rep("DEV=3-004b\n", 'DEV=$(basename "$(ls -d /sys/bus/i2c/devices/*-004b 2>/dev/null | head -n1)" 2>/dev/null)\n[ -n "$DEV" ] || DEV=2-004b\n')
rep('T="i2ctransfer -f -y 3"', 'T="i2ctransfer -f -y ${DEV%%-*}"')
rep("    uname -a\n", '    uname -a\n    echo "== ps"; ps\n    echo "== rc-status"; rc-status -a\n    echo "== dri"; ls -l /dev/dri /sys/class/drm\n    echo "== greetd config"; cat /etc/greetd/config.toml\n')
open(p, "w").write(t)
print("pmos-diag patched")
PY
  grep -n 'DEV=\|i2ctransfer -f\|== ps' "$D" || true
else
  echo "WARN: $D does not exist"
fi

# ---- greeter debugging (why is the greeter UI missing even though phoc + gnome-session run?) ----
SD_DIR="$(dirname "$0")"
install -d "$M/var/log"
# 1) everything the greeter session prints goes to /var/log/phrog-session.log (greetd runs as user greetd, so the file is world-writable)
G="$M/usr/libexec/phrog-greetd-session"
if [ -e "$G" ] && [ ! -e "$G.real" ]; then
  mv "$G" "$G.real"
  install -m 755 "$SD_DIR/phrog-session-wrapper.sh" "$G"
  echo "greeter-fix: wrapped $G"
  head -c 300 "$G.real" | head -n 8 || true
else
  echo "WARN greeter-fix: $G missing or already wrapped, session log not enabled"
fi
: > "$M/var/log/phrog-session.log"
chmod 666 "$M/var/log/phrog-session.log"
# 2) snapshot service: /var/log/pmos-greeter.txt at 45, 90, 180 and 300 s
install -m 755 "$SD_DIR/pmos-greeter-diag.sh" "$M/usr/local/sbin/pmos-greeter-diag"
cat > "$M/etc/init.d/pmos-greeter-diag" <<'EOFSVC'
#!/sbin/openrc-run
description="Greeter diagnostics (/var/log/pmos-greeter.txt)"
depend() {
	need localmount
}
start() {
	ebegin "Saving greeter diagnostics"
	start-stop-daemon --start --background --exec /usr/local/sbin/pmos-greeter-diag
	eend 0
}
EOFSVC
chmod 755 "$M/etc/init.d/pmos-greeter-diag"
ln -sf /etc/init.d/pmos-greeter-diag "$M/etc/runlevels/default/pmos-greeter-diag"
# 3) a syslog, so that dbus, elogind and polkit have somewhere to write (/var/log/messages)
if [ -e "$M/etc/init.d/syslog" ]; then
  mkdir -p "$M/etc/runlevels/boot"
  ln -sf /etc/init.d/syslog "$M/etc/runlevels/boot/syslog"
  echo "greeter-fix: syslog enabled"
else
  echo "WARN greeter-fix: no /etc/init.d/syslog in the image"
fi

sync
umount "$M"
e2fsck -fn "$IMG"
echo "greeter-fix done"
