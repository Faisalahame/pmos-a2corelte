# pmos-a2corelte

postmarketOS for the Samsung Galaxy A2 Core (a2corelte, SM-A260G / SM-A260F), built on GitHub Actions
and packed as ONE TWRP zip that you install with `adb sideload`.

## Build

Actions tab -> **build-pmos** -> Run workflow. Pick the user interface (default `phosh`; also `sxmo-de-sway`,
`xfce4`, `none`). A push to `main` that changes `scripts/**` also starts a build.
The zip is in the run's artifact `pmos-a2corelte` (with a `.sha256` file).

## Install

1. Reboot the phone to TWRP.
2. TWRP: Advanced -> ADB Sideload -> swipe to start.
3. On the PC: `adb sideload pmos-a2corelte.zip`
4. Reboot to system. First boot takes a few minutes (it grows the filesystem to the whole internal storage).

**This erases the internal storage** (USERDATA becomes the postmarketOS root; SYSTEM is not touched).
Do not use TWRP Wipe/Format Data afterwards. Nothing is written until every part of the zip has passed its checksum.

Login: `user` / `147147` (change it with `passwd`). SSH over USB: `ssh user@172.16.42.1`.

## How it works

| step | script |
| --- | --- |
| build postmarketOS (generic `samsung-exynos7` port with the old a2corelte boot.img settings, close-to-mainline Exynos 7870 kernel) | `scripts/build-pmos.sh` |
| fstab, first-boot filesystem grow, sshd, USB network | `scripts/fixup-rootfs.sh` |
| boot image: raw kernel + tiny initramfs so it fits the 32 MB BOOT partition | `scripts/make-boot.py`, `scripts/initramfs-init` |
| the zip (64 MB parts + manifest with md5 sums) | `scripts/make-zip.py` |
| the installer that runs in TWRP | `scripts/update-binary.sh` |

The tiny initramfs mounts the ext4 on USERDATA (or any filesystem labelled `pmOS_root`) and starts the pmOS init.
It also brings up a USB ethernet gadget at 172.16.42.1, so you can reach the phone even if the screen stays dark.
