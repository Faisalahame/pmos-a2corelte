#!/usr/bin/env python3
"""
Touch diagnostic (branch display-6.19): watch the touch chip READ-ONLY, never power-cycle it. Not a fix.

Why: pmos-diag (in scripts/fixup-rootfs.sh) re-probes the touch driver from about 30 s after boot (three unbind/bind tries,
then a module reload) and runs raw i2c tests. Every unbind / module unload switches the touch supply (vdd_ldo35) off and on.
In the logs the chip answers with the same fixed bytes at 7 s and 54 s, then all 00 (66 s), then all ff (78 s, 90 s): it gets worse
after each power cycle. The window between the panel init (about 18.5 s: "TD4101 reset done" + "TD4101 vendor init sent")
and the first re-probe was never read, so we do not know if the chip shows a register map there.

What this script does (edits scripts/fixup-rootfs.sh in the CI checkout, only the end of the pmos-diag script it writes):
  * pmos-diag no longer calls touch_debug (unbind/bind + module reload) and no longer calls raw_i2c
  * a new function touch_watch runs in the background from the start of pmos-diag, every 2 s for about 3 minutes:
      "up=<uptime> bound=<driver bound?> ldo35=<state of vdd_ldo35> 0xe9=[..] 0xe3=[..] 0xdd=[..]"
    the three PDT entries are read like the stock Samsung driver does (write 0xff 0x00 page select, write the address, read 6 bytes)
    with i2ctransfer -f on the touch bus (DEV is looked up at run time by scripts/greeter-fix.sh)
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
touch_watch() {
  command -v i2ctransfer >/dev/null 2>&1 || { echo "(no i2ctransfer binary, touch watch skipped)" > "$TOUT"; return 0; }
  modprobe i2c-dev 2>/dev/null || true
  BUS=${DEV%%-*}
  A=0x4b
  echo "== touch watch (read only) started $(date), uptime $(cut -d' ' -f1 /proc/uptime) s, device $DEV, bus $BUS" > "$TOUT"
  n=0
  while [ $n -lt 85 ]; do
    {
      printf 'up=%s bound=%s ldo35=%s' "$(cut -d' ' -f1 /proc/uptime)" "$([ -e /sys/bus/i2c/devices/$DEV/driver ] && echo yes || echo no)" "$(for r in /sys/class/regulator/regulator.*; do [ "$(cat $r/name 2>/dev/null)" = vdd_ldo35 ] && cat $r/state 2>/dev/null; done)"
      for o in 0xe9 0xe3 0xdd; do
        printf ' %s=[%s]' $o "$(i2ctransfer -f -y $BUS w2@$A 0xff 0x00 w1@$A $o r6@$A 2>&1 | tr '\n' ' ')"
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
exit 0
EOF
# ---- pmos-a2corelte touch watch end ----
'''
s = s.replace(OLD, NEW)
open(P, "w").write(s)
print("scripts/fixup-rootfs.sh patched: read-only touch watch instead of the touch re-probe")
