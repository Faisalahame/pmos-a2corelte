#!/bin/sh
# display-6.19 only: wraps the greeter session so that everything phoc, gnome-session and the greeter print ends up in
# /var/log/phrog-session.log (greetd would otherwise send it to tty7, where nobody reads it).
exec >>/var/log/phrog-session.log 2>&1
echo "=== phrog session start $(date), uptime $(cut -d' ' -f1 /proc/uptime) s, uid $(id -u) ==="
export G_MESSAGES_DEBUG=all
env | sort
exec /usr/libexec/phrog-greetd-session.real "$@"
