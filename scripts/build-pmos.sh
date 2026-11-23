#!/usr/bin/env bash
# display-6.19 branch only. The real build script lives on main and is NOT changed by this branch.
# This wrapper (the workflow runs scripts/build-pmos.sh) takes main's script, switches its kernel package to
# mainline 6.19 with the TD4101 display driver (scripts/apply-display-backport.py explains why), and runs it.
# To build the old 6.15 kernel again, run the workflow on main.
main() {
  set -euo pipefail
  cd "$(dirname "$0")/.."
  git fetch --depth=1 origin main
  git show FETCH_HEAD:scripts/build-pmos.sh > /tmp/build-pmos-main.sh
  cp /tmp/build-pmos-main.sh scripts/build-pmos.sh
  python3 scripts/apply-display-backport.py
  exec bash scripts/build-pmos.sh
}
main "$@"
