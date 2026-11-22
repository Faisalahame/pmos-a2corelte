#!/sbin/sh
# postmarketOS for Samsung Galaxy A2 Core - TWRP installer (pmos-1)
# Writes the postmarketOS root filesystem to the INTERNAL STORAGE (USERDATA) and boot.img to BOOT.
# Send it with "adb sideload pmos-a2corelte.zip" (TWRP: Advanced -> ADB Sideload). SYSTEM is not touched.
# Nothing is written until every check on the zip has passed. There is no backup step.
# Based on the Kali aio-6 installer, including its fixes:
#   - the recovery shell does 32-bit math, so sizes in BYTES over 2 GB wrap around: everything big is counted in KB
#     (awk is only used to print a number, never for a yes/no test)
#   - boot.img ends with the 16 bytes "SEANDROIDENFORCE" after the page-aligned data, so its size is NOT a whole
#     number of KB: BOOT is checked by exact BYTES (the boot image is only ~32 MB, so byte counts are safe)
OUTFD=/proc/self/fd/$2
ZIPFILE="$3"

ui_print() { echo "ui_print $1" > "$OUTFD"; echo "ui_print" > "$OUTFD"; }
abort() { ui_print " "; ui_print "ERROR: $1"; ui_print "Aborting."; exit 1; }

# ---- number helper: bytes (can be over 2 GB, so only awk may touch them) -> KB (small enough for the shell) ----
kb() { awk -v a="$1" 'BEGIN{printf "%.0f", a/1024}'; }

part() {
  for n in "$1" "$(echo "$1" | tr 'A-Z' 'a-z')"; do
    for d in /dev/block/platform/*/by-name /dev/block/by-name; do
      if [ -e "$d/$n" ]; then readlink -f "$d/$n"; return 0; fi
    done
  done
  return 1
}
# size of a block device in KB (the kernel reports 512-byte sectors)
size_kb() { b=$(basename "$1"); s=$(cat "/sys/class/block/$b/size" 2>/dev/null); echo $(( ${s:-0} / 2 )); }
file_kb() { kb "$(ls -l "$1" 2>/dev/null | awk '{print $5}')"; }
# md5 of exactly the first $2 KB of $1, using only dd + md5sum (1 MB blocks when the size allows it)
md5_kb() {
  if [ $(( $2 % 1024 )) -eq 0 ]; then
    dd if="$1" bs=1048576 count=$(( $2 / 1024 )) 2>/dev/null | md5sum | cut -d' ' -f1
  else
    dd if="$1" bs=1024 count="$2" 2>/dev/null | md5sum | cut -d' ' -f1
  fi
}
# md5 of exactly the first $2 BYTES of $1 (only for small sizes: $2 must stay far below 2 GB)
md5_bytes() {
  dd if="$1" bs=1024 count=$(( ($2 + 1023) / 1024 )) 2>/dev/null | head -c "$2" | md5sum | cut -d' ' -f1
}
mf() {
  if [ -n "$2" ]; then echo "$MF" | awk -v k="$1" -v n="$2" '$1==k && $2==n {print $3; exit}'
  else echo "$MF" | awk -v k="$1" '$1==k {print $2; exit}'; fi
}

ui_print "======================================================"
ui_print "  postmarketOS - Galaxy A2 Core - installs to internal storage"
ui_print "  installer pmos-1"
ui_print "======================================================"
DEV=$(getprop ro.product.device)
[ -n "$DEV" ] || DEV=$(getprop ro.build.product)
ui_print "Device: $DEV"
case "$DEV" in a2core*) ;; *) abort "this zip is only for the Galaxy A2 Core (a2corelte), found '$DEV'" ;; esac

BOOT=$(part BOOT) || abort "BOOT partition not found"
UD=$(part USERDATA) || UD=$(part DATA) || abort "USERDATA (internal storage) partition not found"
ui_print "BOOT     : $BOOT"
ui_print "INTERNAL : $UD"
[ "$BOOT" != "$UD" ] || abort "BOOT and USERDATA resolve to the same device"
UD_KB=$(size_kb "$UD")
BOOT_KB=$(size_kb "$BOOT")
ui_print "sizes: BOOT $BOOT_KB KB, INTERNAL $UD_KB KB"
[ "$BOOT_KB" -ge 8192 ] && [ "$BOOT_KB" -le 131072 ] || abort "BOOT partition has an unexpected size ($BOOT_KB KB), not writing anything"
[ "$UD_KB" -ge 4194304 ] || abort "internal storage partition is smaller than 4 GB ($UD_KB KB), not writing anything"

# the zip must come through adb sideload: if it were on the internal storage it would be erased by this install
ZREAL=$(readlink -f "$ZIPFILE")
[ -n "$ZREAL" ] || ZREAL="$ZIPFILE"
case "$ZREAL" in
  /data/*|/sdcard/*|/system/*|/system_root/*) abort "this zip is on the phone's internal storage, which this install erases. Use adb sideload." ;;
esac
ZDEV=$(df -P "$ZREAL" 2>/dev/null | tail -1 | awk '{print $1}')
[ "$ZDEV" != "$UD" ] || abort "this zip is on the internal storage, which this install erases. Use adb sideload."
ZIP_KB=$(file_kb "$ZIPFILE")
[ -n "$ZIP_KB" ] && [ "$ZIP_KB" -ge 1024 ] || abort "cannot read the zip file"

MF=$(unzip -p "$ZIPFILE" pmos.manifest 2>/dev/null)
[ -n "$MF" ] || abort "zip is incomplete or unreadable (manifest missing). Nothing was written."
BOOT_IMG_B=$(mf boot_size); IMG_B=$(mf root_size); NCH=$(mf chunks)
BOOT_MD5=$(mf md5 boot); ROOT_MD5=$(mf md5 root)
[ -n "$BOOT_IMG_B" ] && [ -n "$IMG_B" ] && [ -n "$NCH" ] && [ -n "$BOOT_MD5" ] && [ -n "$ROOT_MD5" ] || abort "zip manifest is damaged. Nothing was written."
# the boot image is ~32 MB: at most 9 digits, so its byte count is safe for the shell's 32-bit math
[ "${#BOOT_IMG_B}" -le 9 ] || abort "boot image size in the manifest is not valid. Nothing was written."
BOOT_IMG_KB=$(( (BOOT_IMG_B + 1023) / 1024 )); IMG_KB=$(kb "$IMG_B")
ui_print "rootfs image $((IMG_KB/1024)) MB -> internal storage $((UD_KB/1024)) MB (grown to full size on first boot)"
ui_print "boot image   $BOOT_IMG_B bytes -> BOOT $BOOT_KB KB"
[ "$IMG_KB" -gt 0 ] && [ "$IMG_KB" -le "$UD_KB" ] || abort "internal storage is too small for the postmarketOS image"
[ "$BOOT_IMG_KB" -gt 0 ] && [ "$BOOT_IMG_KB" -le "$BOOT_KB" ] || abort "boot.img does not fit in the BOOT partition. Nothing was written."

# the read-back checks must work BEFORE anything is erased: test them on the BOOT partition, whose md5 we can compare with itself
ui_print "Testing the read-back check on BOOT..."
T1=$(md5_kb "$BOOT" "$BOOT_KB"); T2=$(md5_kb "$BOOT" "$BOOT_KB")
[ "$T1" = "$T2" ] && [ "$T1" != "d41d8cd98f00b204e9800998ecf8427e" ] || abort "cannot read the BOOT partition back (md5 $T1 / $T2). Nothing was written."
# the exact-bytes check (head -c) must work too, otherwise BOOT could not be verified after writing it
HC=$(dd if=/dev/zero bs=1024 count=2 2>/dev/null | head -c 1500 | wc -c)
[ "$(( HC + 0 ))" -eq 1500 ] || abort "this recovery's 'head -c' does not work, BOOT could not be verified. Nothing was written."
B1=$(md5_bytes "$BOOT" "$BOOT_IMG_B"); B2=$(md5_bytes "$BOOT" "$BOOT_IMG_B")
[ "$B1" = "$B2" ] && [ "$B1" != "d41d8cd98f00b204e9800998ecf8427e" ] || abort "cannot read the BOOT partition back by bytes (md5 $B1 / $B2). Nothing was written."

ui_print "Checking the zip (a few minutes)..."
got=$(unzip -p "$ZIPFILE" boot.img 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$got" = "$BOOT_MD5" ] || abort "boot.img in the zip is bad (want $BOOT_MD5, got $got). Nothing was written."
i=0
while [ "$i" -lt "$NCH" ]; do
  n=$(printf "c%02d" "$i")
  want=$(mf md5 "$n")
  [ -n "$want" ] || abort "manifest has no checksum for part $n. Nothing was written."
  got=$(unzip -p "$ZIPFILE" "root/$n.img" 2>/dev/null | md5sum | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    got=$(unzip -p "$ZIPFILE" "root/$n.img" 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
      bytes=$(unzip -p "$ZIPFILE" "root/$n.img" 2>/dev/null | wc -c)
      ui_print "part $n: want $want"
      ui_print "part $n: got  $got"
      ui_print "part $n: $bytes bytes read, expected $(mf size "$n")"
      abort "part $n of the root image failed its check. Nothing was written."
    fi
  fi
  i=$((i+1))
  [ $((i % 4)) -eq 0 ] && ui_print "  checked $i of $NCH parts"
done
ui_print "Zip is intact."

ui_print " "
ui_print "ERASING the internal storage (Android data and photos) and writing postmarketOS..."
# release the internal storage
umount /sdcard 2>/dev/null; umount /data/media 2>/dev/null; umount /data 2>/dev/null; umount "$UD" 2>/dev/null
grep -q "^$UD " /proc/mounts && abort "cannot unmount the internal storage ($UD). Nothing was written."
rm -f /tmp/unz-failed /tmp/dd-write.log
(
  i=0
  while [ "$i" -lt "$NCH" ]; do
    unzip -p "$ZIPFILE" "$(printf "root/c%02d.img" "$i")" || { touch /tmp/unz-failed; exit 1; }
    i=$((i+1))
  done
) | dd of="$UD" bs=1048576 2>/tmp/dd-write.log
DDRC=$?
sync
if [ -e /tmp/unz-failed ] || [ "$DDRC" -ne 0 ]; then
  ui_print "dd exit code $DDRC; $(tail -n 2 /tmp/dd-write.log 2>/dev/null | tr '\n' ' ')"
  abort "writing the rootfs failed - the internal storage is now broken, re-flash this zip"
fi
ui_print "Verifying..."
GOT=$(md5_kb "$UD" "$IMG_KB")
if [ "$ROOT_MD5" != "$GOT" ]; then
  # help find out what went wrong: compare the first MB on the phone with the first MB of the zip
  ui_print "read-back bytes (first 1 MB test): $(dd if="$UD" bs=32768 count=32 2>/dev/null | wc -c)"
  ui_print "phone first MB md5: $(dd if="$UD" bs=32768 count=32 2>/dev/null | md5sum | cut -d' ' -f1)"
  ui_print "zip   first MB md5: $(unzip -p "$ZIPFILE" root/c00.img 2>/dev/null | dd bs=32768 count=32 2>/dev/null | md5sum | cut -d' ' -f1)"
  abort "rootfs verification failed (want $ROOT_MD5, got $GOT) - re-flash this zip"
fi
ui_print "Root filesystem written and verified."

ui_print "Writing boot image to BOOT..."
unzip -p "$ZIPFILE" boot.img | dd of="$BOOT" bs=1048576 2>/dev/null || abort "writing BOOT failed - re-flash this zip"
sync
GOT=$(md5_bytes "$BOOT" "$BOOT_IMG_B")
if [ "$BOOT_MD5" != "$GOT" ]; then
  ui_print "BOOT md5 (exact $BOOT_IMG_B bytes): $GOT"
  ui_print "boot.img md5 in the zip           : $BOOT_MD5"
  ui_print "phone BOOT first MB md5: $(md5_kb "$BOOT" 1024)"
  ui_print "zip   boot.img first MB md5: $(unzip -p "$ZIPFILE" boot.img 2>/dev/null | dd bs=1048576 count=1 2>/dev/null | md5sum | cut -d' ' -f1)"
  abort "BOOT verification failed - re-flash this zip"
fi
ui_print "Boot image verified."

ui_print " "
ui_print "Done. Reboot to system (TWRP may say 'Failed to mount /data': normal)."
ui_print "First boot takes a few minutes (it grows the filesystem to the whole"
ui_print "internal storage, then the desktop appears)."
ui_print "Login: user / 147147 (change it with passwd)."
ui_print "SSH over USB: ssh user@172.16.42.1"
ui_print "Do NOT use TWRP Wipe/Format Data afterwards: postmarketOS lives there now."
exit 0
