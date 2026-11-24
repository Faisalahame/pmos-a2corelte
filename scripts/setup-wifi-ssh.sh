#!/usr/bin/env bash
# Makes the phone join your mobile hotspot on boot and run sshd, so you can SSH in from Termux (no PC needed).
#   * NetworkManager profile for the hotspot (SSID / password below), autoconnect
#   * sshd + networkmanager + dbus switched on (OpenRC), password login allowed
#   * pmos-wifi service: un-blocks Wi-Fi, reloads the brcmfmac driver if no wlan interface showed up (the first load
#     fails on kernel 6.19 while Bluetooth loads its firmware), retries "nmcli connection up" for about 2 minutes and
#     writes /var/log/pmos-wifi.txt (IP address, interface, Wi-Fi driver / firmware lines): readable from TWRP
#   * the same service prints a one-line Wi-Fi status on the phone screen (/dev/tty1) every 8 s for about 6 minutes
# usage: sudo bash scripts/setup-wifi-ssh.sh work/pmos-root.img
set -euxo pipefail
IMG="${1:?usage: setup-wifi-ssh.sh root.img}"
WIFI_SSID="${WIFI_SSID:-faisal}"
WIFI_PSK="${WIFI_PSK:-12345678}"
M=$(mktemp -d)
cleanup() { mountpoint -q "$M" && umount "$M"; rmdir "$M" 2>/dev/null || true; }
trap cleanup EXIT

mount -o loop,rw "$IMG" "$M"

echo "== what the image has for Wi-Fi / SSH =="
ls "$M"/usr/sbin/NetworkManager "$M"/usr/bin/NetworkManager 2>&1 || echo "WARN: NetworkManager binary not found"
ls "$M"/usr/sbin/wpa_supplicant "$M"/sbin/wpa_supplicant 2>&1 || echo "WARN: wpa_supplicant not found"
ls "$M"/usr/bin/nmcli 2>&1 || echo "WARN: nmcli not found (the retry helper will only log)"
ls "$M"/usr/sbin/sshd 2>&1 || echo "WARN: sshd not found (openssh missing?)"
ls "$M"/lib/firmware 2>&1 | head -n 40 || true
ls -l "$M"/lib/firmware/brcm 2>&1 | grep -iE '43430|a2core' || echo "WARN: no 43430 / a2core files in /lib/firmware/brcm"

# ---- Wi-Fi NVRAM: the phone's own (BCM43436B0, "A2_CORE rev01", xtalfreq 37.4 MHz), taken from the stock vendor.img ----
# The image used to link these names to the Raspberry Pi Zero 2 W NVRAM, which is for another board. brcmfmac asks for the
# board-specific name first (samsung,a2corelte), then the plain name; both now get the A2 Core file. The firmware .bin and
# the .clm_blob stay as they are.
NVRAM_SRC="$(dirname "$0")/../firmware/brcmfmac43430b0-sdio.samsung,a2corelte.txt"
[ -s "$NVRAM_SRC" ] || { echo "ERROR: $NVRAM_SRC missing"; exit 1; }
grep -q '^xtalfreq=37400' "$NVRAM_SRC" || { echo "ERROR: $NVRAM_SRC is not the A2 Core NVRAM"; exit 1; }
install -d -m 755 "$M/lib/firmware/brcm"
for n in brcmfmac43430b0-sdio.samsung,a2corelte.txt brcmfmac43430b0-sdio.txt; do
  rm -f "$M/lib/firmware/brcm/$n"
  install -m 644 "$NVRAM_SRC" "$M/lib/firmware/brcm/$n"
done
ls -l "$M"/lib/firmware/brcm | grep -iE '43430|43436|a2core'
cmp "$NVRAM_SRC" "$M/lib/firmware/brcm/brcmfmac43430b0-sdio.txt" && echo "A2 Core Wi-Fi NVRAM installed"

# ---- NetworkManager profile for the hotspot ----
UUID=$(cat /proc/sys/kernel/random/uuid)
install -d -m 755 "$M/etc/NetworkManager/system-connections" "$M/etc/NetworkManager/conf.d"
cat > "$M/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection" <<NMEOF
[connection]
id=$WIFI_SSID
uuid=$UUID
type=wifi
autoconnect=true
autoconnect-priority=100
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
method=ignore
NMEOF
chmod 600 "$M/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection"
chown 0:0 "$M/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection"

# Wi-Fi power saving off (flaky on old Samsung drivers)
cat > "$M/etc/NetworkManager/conf.d/20-pmos-wifi.conf" <<'NMEOF'
[connection]
wifi.powersave=2
NMEOF

# ---- sshd: password login allowed (first matching line wins, so it goes to the very top) ----
if [ -f "$M/etc/ssh/sshd_config" ]; then
  sed -i '/^#*[[:space:]]*PasswordAuthentication/d' "$M/etc/ssh/sshd_config"
  sed -i '1i PasswordAuthentication yes' "$M/etc/ssh/sshd_config"
else
  echo "WARN: no /etc/ssh/sshd_config in the image"
fi

# ---- Wi-Fi helper: reloads the driver if needed, retries the connection and logs the state ----
install -d "$M/usr/local/sbin" "$M/var/log"
cat > "$M/usr/local/sbin/pmos-wifi" <<'WEOF'
#!/bin/sh
# pmos-wifi v2: joins the hotspot after boot. Reloads brcmfmac when the first load failed (no wlan interface).
# Log: /var/log/pmos-wifi.txt (readable from TWRP). A one-line status is also printed on the phone screen.
OUT=/var/log/pmos-wifi.txt
SSID="__SSID__"
log() { echo "$*" >> "$OUT"; sync; }
screen() { echo "[pmos-wifi] $*" > /dev/tty1 2>/dev/null || true; }
have_wlan() { ls /sys/class/net | grep -q '^wl'; }
status() {
  IF=$(ls /sys/class/net | grep '^wl' | head -n1)
  if [ -z "$IF" ]; then
    screen "no wlan interface: Wi-Fi driver/firmware not loaded"
  else
    IP=$(ip -4 addr show "$IF" 2>/dev/null | awk '/inet /{print $2}')
    ST=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^$IF:" | cut -d: -f2)
    SEEN=$(nmcli -t -f SSID device wifi list 2>/dev/null | grep -cx "$SSID")
    NM=down; pidof NetworkManager >/dev/null 2>&1 && NM=up
    SS=down; pidof sshd >/dev/null 2>&1 && SS=up
    screen "$IF state=${ST:-?} ip=${IP:-none} ssid_seen=$SEEN nm=$NM sshd=$SS"
  fi
}
status_loop() { n=0; while [ $n -lt 45 ]; do status; n=$((n+1)); sleep 8; done; }
connected() { nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q '^wl.*:connected$'; }
snap() {
  {
    echo "== state at $(date), uptime $(cut -d' ' -f1 /proc/uptime) s"
    echo "-- interfaces"; ls /sys/class/net
    echo "-- ip addr"; ip addr 2>&1
    echo "-- rfkill"; rfkill list 2>&1
    echo "-- nmcli device"; nmcli device status 2>&1
    echo "-- nmcli wifi list"; nmcli -f SSID,SIGNAL,CHAN,FREQ device wifi list 2>&1
    echo "-- nmcli connection"; nmcli connection show 2>&1
    echo "-- processes"; ps | grep -E 'NetworkManager|wpa_supplicant|sshd' | grep -v grep
    echo "-- wifi modules"; lsmod | grep -iE '80211|brcm|bcm|wlan|cfg|hci'
    echo "-- wifi lines of dmesg"; dmesg | grep -iE 'wlan|wifi|wl:|brcm|bcm|cfg80211|firmware|sdio|mmc|ieee80211|Bluetooth' | tail -n 80
  } >> "$OUT" 2>&1
  sync
}
: > "$OUT"
log "== pmos-wifi v2 started at $(date), SSID $SSID"
status_loop &
rfkill unblock all >/dev/null 2>&1
sleep 20
n=1
while [ $n -le 5 ] && ! have_wlan; do
  log "-- reload $n: brcmfmac"
  if [ $n -ge 3 ]; then
    log "-- (attempt $n: unloading the Bluetooth UART driver first)"
    modprobe -r hci_uart btbcm >> "$OUT" 2>&1
  fi
  modprobe -r brcmfmac_wcc brcmfmac >> "$OUT" 2>&1
  sleep 3
  modprobe brcmfmac >> "$OUT" 2>&1
  sleep 15
  log "$(dmesg | grep -iE 'brcmf|ieee80211' | tail -n 8)"
  n=$((n+1))
done
have_wlan || log "!! no wlan interface after the reloads: the Wi-Fi driver / firmware is not working in this kernel"
snap
if command -v nmcli >/dev/null 2>&1; then
  n=1
  while [ $n -le 12 ]; do
    if connected; then log "-- CONNECTED"; break; fi
    nmcli radio wifi on >/dev/null 2>&1
    nmcli device wifi rescan >/dev/null 2>&1
    sleep 5
    log "-- try $n: nmcli connection up $SSID"
    nmcli connection up "$SSID" >> "$OUT" 2>&1
    sleep 8
    n=$((n+1))
  done
else
  log "(no nmcli, waiting for NetworkManager to autoconnect)"
  sleep 60
fi
snap
sleep 90
snap
exit 0
WEOF
sed -i "s|__SSID__|$WIFI_SSID|" "$M/usr/local/sbin/pmos-wifi"
chmod 755 "$M/usr/local/sbin/pmos-wifi"

# ---- OpenRC services ----
if [ -d "$M/etc/init.d" ]; then
  cat > "$M/etc/init.d/pmos-wifi" <<'REOF'
#!/sbin/openrc-run
description="Join the hotspot and log the Wi-Fi state (/var/log/pmos-wifi.txt)"
depend() {
	need localmount
	after networkmanager
}
start() {
	ebegin "Wi-Fi hotspot helper"
	start-stop-daemon --start --background --exec /usr/local/sbin/pmos-wifi
	eend 0
}
REOF
  chmod 755 "$M/etc/init.d/pmos-wifi"
  mkdir -p "$M/etc/runlevels/default"
  for s in dbus networkmanager sshd pmos-wifi; do
    if [ -e "$M/etc/init.d/$s" ]; then
      ln -sf "/etc/init.d/$s" "$M/etc/runlevels/default/$s"
      echo "enabled $s"
    else
      echo "WARN: /etc/init.d/$s does not exist in the image"
    fi
  done
  ls -la "$M/etc/runlevels/default"
else
  echo "WARN: no /etc/init.d: not an OpenRC image"
fi

sync
umount "$M"
e2fsck -fn "$IMG"
echo "wifi + ssh setup done"
