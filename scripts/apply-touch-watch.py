#!/usr/bin/env python3
"""
Touch diagnostic v2 (branch display-6.19): watch the touch chip READ-ONLY, never power-cycle it. Not a fix.

Why: pmos-diag (in scripts/fixup-rootfs.sh) re-probes the touch driver from about 30 s after boot (three unbind/bind tries,
then a module reload) and runs raw i2c tests. Every unbind / module unload switches the touch supply (vdd_ldo35) off and on.
Watch build 1 showed: the chip answers after the panel init (about 18.5 s), but the register address we write is not honoured
(the three PDT reads come back as one advancing byte stream; at about 41.8 s the bytes spell "TD4101"), then the chip returns
00 (about 63 s), ff (about 65 to 173 s) and NACK (from about 175 s) with no power cycling by us.

What this script does (edits scripts/fixup-rootfs.sh in the CI checkout, only the end of the pmos-diag script it writes):
  * pmos-diag no longer calls touch_debug (unbind/bind + module reload) and no longer calls raw_i2c
  * a new function touch_watch runs in the background from the start of pmos-diag, every 2 s for about 4.5 minutes (the last pmos-diag snapshot is at about 280 s). One line per sample:
      "up=<uptime> bound=.. ldo35=.. disp:<display/backlight state> raw=[..] 0xe9=[..] 0xe3=[..] 0xdd=[..] sp0xe9=[..] sp0xdd=[..]"
    - disp: bl_power / actual_brightness of the backlight, DSI connector enabled + dpms, fb0 blank (whatever exists), so the
      changes of the chip's answer can be lined up with the screen going to sleep
    - raw: a read with NO address written first (6 bytes): is the chip streaming by itself?
    - 0xe9 / 0xe3 / 0xdd: the three PDT entries read like the stock Samsung driver (write 0xff 0x00 page select, write the address,
      read 6 bytes, one i2ctransfer with three messages)
    - sp0xe9 / sp0xdd: the same entries, but page select, address write and read are THREE SEPARATE i2ctransfer calls, so there is a STOP
      between the address write and the read. If the chip only latches the address after a STOP, this is the one that shows a valid PDT
  * the lines go to /var/log/pmos-touch-debug.txt (also copied into /var/log/pmos-diag.txt), readable over SSH or from TWRP
Compare the "up=" times with the dmesg lines "TD4101 reset done" and "TD4101 vendor init sent" in the same pmos-diag.txt.
The touch driver is NOT re-probed in this build, so touch stays dead; the point is only to see what the chip returns over time.
"""
import sys

P = "scripts/fixup-rootfs.sh"
s = open(P).read()
if "pmos-a2corelte touch watch" in s:
    print("touch watch already applied")
    sys.exit(0)

OLD = "sleep 25; snap\nsleep 5; touch_debug\nraw_i2c\nsnap\nsleep 90; snap\nexit 0\nEOF\n"
n = s.count(OLD)
assert n == 1, "end of pmos-diag not found exactly once (%d)" % n

NEW = r'''# ---- pmos-a2corelte touch watch begin ----
# Read-only watch of the touch chip (diagnostic, scripts/apply-touch-watch.py): no unbind, no module reload, so vdd_ldo35 is never switched.
disp_state() {
  for f in /sys/class/backlight/*/bl_power /sys/class/backlight/*/actual_brightness /sys/class/drm/card*-DSI-*/enabled /sys/class/drm/card*-DSI-*/dpms /sys/class/graphics/fb0/blank; do
    [ -r "$f" ] && printf ' %s=%s' "${f#/sys/class/}" "$(cat $f 2>/dev/null)"
  done
  return 0
}

touch_watch() {
  command -v i2ctransfer >/dev/null 2>&1 || { echo "(no i2ctransfer binary, touch watch skipped)" > "$TOUT"; return 0; }
  modprobe i2c-dev 2>/dev/null || true
  BUS=${DEV%%-*}
  A=0x4b
  echo "== touch watch v2 (read only) started $(date), uptime $(cut -d' ' -f1 /proc/uptime) s, device $DEV, bus $BUS" > "$TOUT"
  n=0
  while [ $n -lt 120 ]; do
    {
      printf 'up=%s bound=%s ldo35=%s disp:%s' "$(cut -d' ' -f1 /proc/uptime)" "$([ -e /sys/bus/i2c/devices/$DEV/driver ] && echo yes || echo no)" "$(for r in /sys/class/regulator/regulator.*; do [ "$(cat $r/name 2>/dev/null)" = vdd_ldo35 ] && cat $r/state 2>/dev/null; done)" "$(disp_state)"
      printf ' raw=[%s]' "$(i2ctransfer -f -y $BUS r6@$A 2>&1 | tr '\n' ' ')"
      for o in 0xe9 0xe3 0xdd; do
        printf ' %s=[%s]' $o "$(i2ctransfer -f -y $BUS w2@$A 0xff 0x00 w1@$A $o r6@$A 2>&1 | tr '\n' ' ')"
      done
      for o in 0xe9 0xdd; do
        i2ctransfer -f -y $BUS w2@$A 0xff 0x00 >/dev/null 2>&1
        i2ctransfer -f -y $BUS w1@$A $o >/dev/null 2>&1
        printf ' sp%s=[%s]' $o "$(i2ctransfer -f -y $BUS r6@$A 2>&1 | tr '\n' ' ')"
      done
      echo
    } >> "$TOUT" 2>&1
    sync
    n=$((n+1))
    sleep 2
  done
}

touch_watch &
sleep 25; snap
sleep 65; snap
sleep 90; snap
sleep 100; snap
exit 0
EOF
# ---- pmos-a2corelte touch watch end ----
'''
s = s.replace(OLD, NEW)
open(P, "w").write(s)
print("scripts/fixup-rootfs.sh patched: read-only touch watch v2 instead of the touch re-probe")
