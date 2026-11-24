#!/usr/bin/env bash
# display-6.19 branch only. The real build script lives on main and is NOT changed by this branch.
# This wrapper (the workflow runs scripts/build-pmos.sh) takes main's script, switches its kernel package to
# mainline 6.19 with the TD4101 display driver (scripts/apply-display-backport.py explains why), makes the kernel
# compile use ccache (scripts/apply-ccache.py), enables the Samsung PMIC driver that 6.19 moved to a new config
# symbol (scripts/apply-pmic-fix.py), gives the TD4101 panel its reset line so the touch part of the chip
# comes up (scripts/apply-panel-reset.py), and runs it.
# scripts/apply-greeter-fix.py hooks scripts/greeter-fix.sh into fixup-rootfs.sh (greeter waits for the display).
# To build the old 6.15 kernel again, run the workflow on main.
main() {
  set -euo pipefail
  cd "$(dirname "$0")/.."
  git fetch --depth=1 origin main
  git show FETCH_HEAD:scripts/build-pmos.sh > /tmp/build-pmos-main.sh
  cp /tmp/build-pmos-main.sh scripts/build-pmos.sh
  python3 scripts/apply-display-backport.py
  python3 scripts/apply-ccache.py
  python3 scripts/apply-pmic-fix.py
  python3 scripts/apply-panel-reset.py
  python3 scripts/apply-wifi-fix.py
  python3 scripts/apply-sdio-fix.py
  python3 scripts/apply-greeter-fix.py
  exec bash scripts/build-pmos.sh
}
main "$@"
