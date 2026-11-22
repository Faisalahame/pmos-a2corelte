#!/usr/bin/env python3
"""Build the TWRP zip (install with: adb sideload).

usage: make-zip.py OUT.zip BOOT.img ROOT.img update-binary

Layout:
  META-INF/com/google/android/update-binary, updater-script
  pmos.manifest          sizes and md5 of everything
  boot.img
  root/c00.img ...       the ext4 image in 64 MiB parts (the recovery's unzip chokes on one huge entry)
"""
import hashlib, os, sys, zipfile

CHUNK = 64 * 1024 * 1024
VERSION = 1


def main():
    out, boot, root, ub = sys.argv[1:5]
    bootdata = open(boot, "rb").read()
    rsize = os.path.getsize(root)
    nch = (rsize + CHUNK - 1) // CHUNK
    mf = [f"version {VERSION}", f"boot_size {len(bootdata)}", f"root_size {rsize}",
          f"chunk_mb {CHUNK // 1048576}", f"chunks {nch}",
          f"md5 boot {hashlib.md5(bootdata).hexdigest()}"]
    allmd5 = hashlib.md5()
    with open(root, "rb") as f:
        for i in range(nch):
            b = f.read(CHUNK)
            allmd5.update(b)
            mf.append(f"md5 c{i:02d} {hashlib.md5(b).hexdigest()}")
            mf.append(f"size c{i:02d} {len(b)}")
            if i % 8 == 7:
                print(f"hashed {i + 1}/{nch}", flush=True)
    mf.insert(6, f"md5 root {allmd5.hexdigest()}")
    manifest = "\n".join(mf) + "\n"

    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
        def add(name, data, mode=0o644):
            zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = mode << 16
            z.writestr(zi, data, compresslevel=6)
        add("META-INF/com/google/android/update-binary", open(ub, "rb").read(), 0o755)
        add("META-INF/com/google/android/updater-script", b"# dummy: update-binary is a shell script\n")
        add("pmos.manifest", manifest.encode())
        add("boot.img", bootdata)
        with open(root, "rb") as f:
            for i in range(nch):
                add(f"root/c{i:02d}.img", f.read(CHUNK))
                if i % 8 == 7:
                    print(f"zipped {i + 1}/{nch}", flush=True)

    # read everything back out of the finished zip and compare with the manifest
    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad:
            sys.exit("zip test failed at " + bad)
        if hashlib.md5(z.read("boot.img")).hexdigest() != mf[5].split()[2]:
            sys.exit("boot.img md5 mismatch after zipping")
        h = hashlib.md5()
        for i in range(nch):
            b = z.read(f"root/c{i:02d}.img")
            h.update(b)
        if h.hexdigest() != allmd5.hexdigest():
            sys.exit("root image md5 mismatch after zipping")
    print(f"OK {out}: {os.path.getsize(out) // 1048576} MB, {nch} parts, root {rsize} bytes")


if __name__ == "__main__":
    main()
