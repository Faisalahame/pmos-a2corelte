#!/bin/bash
# display-6.19 only: replacement for /usr/libexec/phrog-greetd-session (the original is kept as .real).
# Same steps as the original, with one change: output goes to /var/log/phrog-session.log instead of through
# "logger -s -t phrog". With syslogd running, logger died ("socket /dev/log: Connection refused"), the pipe broke,
# and phoc was killed again and again (43 greeter sessions in 5 minutes, see the first logs of this branch).
PHOC_INI=/etc/phrog/phoc.ini
[ ! -f $PHOC_INI ] && PHOC_INI=/usr/share/phrog/phoc.ini
[ ! -f $PHOC_INI ] && PHOC_INI=/etc/phosh/phoc.ini
[ ! -f $PHOC_INI ] && PHOC_INI=/usr/share/phosh/phoc.ini

export XDG_CURRENT_DESKTOP=Phrog:Phosh:GNOME
export GNOME_SESSION_AUTOSTART_DIR=/usr/share/phrog/autostart:/etc/phrog/autostart
export G_MESSAGES_DEBUG=all

exec >>/var/log/phrog-session.log 2>&1
echo "=== phrog session start $(date), uptime $(cut -d' ' -f1 /proc/uptime) s, pid $$ ==="

dbus_command=""
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  dbus_command=dbus-run-session
fi

exec $dbus_command phoc -S -C "${PHOC_INI}" -E 'gnome-session --session=phrog'
