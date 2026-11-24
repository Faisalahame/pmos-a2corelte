#!/bin/sh
# display-6.19 only. Why does the greeter (phrog on phoc) not show up? Rewrites /var/log/pmos-greeter.txt at about
# 45 s, 90 s, 180 s and 300 s of uptime (so wait 5+ minutes before going to TWRP). The log of the greeter session itself
# is /var/log/phrog-session.log (written by the wrapper around /usr/libexec/phrog-greetd-session).
OUT=/var/log/pmos-greeter.txt
up() { cut -d' ' -f1 /proc/uptime; }

# start the greeter shell by hand with the session's environment, but only if it is not running: its own error
# messages (and "exit 124" = it kept running until the 25 s timeout = it starts fine) are the answer we are after
live_probe() {
  if pidof phrog >/dev/null 2>&1; then echo "phrog is running (pid $(pidof phrog))"; return 0; fi
  GS=$(pidof gnome-session-binary | awk '{print $1}')
  [ -n "$GS" ] || GS=$(pidof phoc | awk '{print $1}')
  [ -n "$GS" ] || { echo "no gnome-session / phoc process, no probe"; return 0; }
  EXEC=$(grep -h '^Exec=' /usr/share/applications/sm.puri.Phrog.desktop /usr/share/applications/*hrog*.desktop 2>/dev/null | head -n1 | sed 's/^Exec=//; s/ %.*//')
  [ -n "$EXEC" ] || EXEC=$(command -v phrog)
  echo "phrog is NOT running. gnome-session pid $GS, trying by hand: $EXEC"
  [ -n "$EXEC" ] || return 0
  {
    tr '\0' '\n' < /proc/$GS/environ | grep -E '^(DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|WAYLAND_DISPLAY|XDG_SESSION_ID|XDG_SEAT|XDG_VTNR|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|XDG_DATA_DIRS)=' | sed 's/^/export /'
    echo "export G_MESSAGES_DEBUG=all"
    echo "cd /tmp"
    echo "timeout 25 $EXEC; echo \"probe exit code \$?\""
  } > /tmp/phrog-probe.sh
  chmod 755 /tmp/phrog-probe.sh
  su -s /bin/sh greetd -c "/bin/sh /tmp/phrog-probe.sh" 2>&1 | tail -n 80
}

snap() {
  {
    echo "== pmos-greeter-diag pass $1 at $(date), uptime $(up) s"
    echo "== ps (greeter related)"
    ps -o pid,ppid,user,time,etime,args 2>/dev/null | grep -E 'greetd|phoc|gnome-session|phrog|phosh|stevia|gsd-|dbus|elogind|accounts|polkit|feedbackd' | grep -v grep \
      || ps | grep -E 'greetd|phoc|gnome-session|phrog|phosh|stevia|gsd-|dbus|elogind|accounts|polkit|feedbackd' | grep -v grep
    echo "== top"; top -b -n 1 2>/dev/null | head -n 15
    echo "== state of the greeter processes"
    for p in $(pidof phoc gnome-session-binary phrog phosh-osk-stevia 2>/dev/null); do
      echo "pid $p $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-80): $(grep -E '^State' /proc/$p/status) wchan=$(cat /proc/$p/wchan 2>/dev/null)"
    done
    echo "== who holds a DRM device"
    ls -l /proc/[0-9]*/fd 2>/dev/null | grep -E 'dri/(card|render)' | sort | uniq -c | head -n 20
    echo "== DRM connectors"
    for c in /sys/class/drm/card*-*; do
      [ -e "$c/status" ] || continue
      echo "$c status=$(cat $c/status) enabled=$(cat $c/enabled 2>/dev/null) dpms=$(cat $c/dpms 2>/dev/null) modes=$(head -n 2 $c/modes 2>/dev/null | tr '\n' ' ')"
    done
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
    echo "== DRM atomic state (debugfs)"; cat /sys/kernel/debug/dri/*/state 2>&1 | head -n 90
    echo "== greeter session files"
    echo "-- /usr/libexec/phrog-greetd-session(.real)"
    for f in /usr/libexec/phrog-greetd-session.real /usr/libexec/phrog-greetd-session; do
      [ -e "$f" ] || continue
      echo "- $f"; if head -c 4 "$f" | grep -q ELF; then echo "(binary)"; else head -n 40 "$f"; fi
    done
    echo "-- sessions"; ls /usr/share/gnome-session/sessions/ 2>&1
    echo "-- phrog.session"; cat /usr/share/gnome-session/sessions/phrog.session 2>&1
    echo "-- desktop files"; grep -H '^Exec=' /usr/share/applications/sm.puri.*.desktop /usr/share/applications/*hrog*.desktop 2>&1 | head -n 20
    echo "-- phrog binaries"; ls -l /usr/bin/phrog* /usr/libexec/phrog* /usr/libexec/phosh* 2>&1
    echo "-- phoc.ini"; cat /usr/share/phosh/phoc.ini 2>&1 | head -n 30
    echo "== rc-service polkit / logbookd"; rc-service polkit status 2>&1; rc-service logbookd status 2>&1
    echo "== loginctl"; loginctl list-sessions 2>&1 | head -n 10
    echo "== kernel log: drm / panel / gpu / crashes"
    dmesg | grep -iE 'drm|dsi|panel|decon|panfrost|segfault|unhandled|audit|oom|killed' | tail -n 40
    echo "== /var/log/phrog-session.log (last 400 lines)"; tail -n 400 /var/log/phrog-session.log 2>&1
    if [ -e /var/log/messages ]; then echo "== /var/log/messages (last 300 lines)"; tail -n 300 /var/log/messages; else echo "(no /var/log/messages: no syslog)"; fi
    echo "== live probe of the greeter shell"
    if [ "$1" -ge 2 ]; then live_probe; else echo "(only from pass 2)"; fi
    echo "== end of pass $1"
  } > "$OUT.tmp" 2>&1
  mv -f "$OUT.tmp" "$OUT"
  sync
}

sleep 45;  snap 1
sleep 45;  snap 2
sleep 90;  snap 3
sleep 120; snap 4
exit 0
