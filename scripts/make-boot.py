#!/usr/bin/env python3
"""Turn the postmarketOS boot.img (built by build-pmos.sh) into the boot image the Galaxy A2 Core boots.

usage: make-boot.py IN-boot.img initramfs-init OUT-boot.img

What changes compared to the pmOS image (all of it was found by testing on the real phone):
  * the kernel is stored RAW (uncompressed): Samsung's bootloader does not decompress it
  * the 23 MB pmOS initramfs is replaced by a tiny one (busybox + musl from the pmOS initramfs + our init),
    so everything fits into the 32 MB BOOT partition
  * the kernel command line is ours
  * "SEANDROIDENFORCE" is appended at the end, like on Samsung's own images
"""
import gzip, hashlib, struct, subprocess, sys, zlib

PAGE_FALLBACK = 2048
BOOT_PART = 32 * 1024 * 1024
CMDLINE = ("console=tty0 ignore_loglevel printk.time=1 clk_ignore_unused pd_ignore_unused "
           "initcall_blacklist=efifb_driver_init pmos_rootfsopts=defaults")


def die(msg):
    sys.exit("make-boot: ERROR: " + msg)


def decompress_stream(blob):
    """decompress a ramdisk of unknown format (gzip, zstd, lz4, xz, bzip2, or plain cpio)"""
    if blob[:6] == b"070701":
        return blob
    tools = {b"\x1f\x8b": ["gzip", "-dc"], b"\x28\xb5\x2f\xfd": ["zstd", "-dc"],
             b"\x04\x22\x4d\x18": ["lz4", "-dc"], b"\x02\x21\x4c\x18": ["lz4", "-dc"],
             b"\xfd7zXZ": ["xz", "-dc"], b"BZh": ["bzip2", "-dc"]}
    for magic, cmd in tools.items():
        if blob.startswith(magic):
            p = subprocess.run(cmd, input=blob, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            # trailing padding makes gzip return 2 ("trailing garbage"); the data is still complete
            if p.stdout[:6] == b"070701":
                return p.stdout
            die("could not decompress the ramdisk with %s: %s" % (cmd[0], p.stderr.decode()[:200]))
    die("unknown ramdisk format, first bytes %r" % blob[:8])


def cpio_read(data):
    ents, p = [], 0
    while True:
        if data[p:p + 6] != b"070701":
            die("bad cpio at offset %d" % p)
        f = lambda i: int(data[p + 6 + 8 * i:p + 14 + 8 * i], 16)
        mode, size, ns = f(1), f(6), f(11)
        name = data[p + 110:p + 110 + ns - 1].decode()
        p = (p + 110 + ns + 3) & ~3
        body = data[p:p + size]
        p = (p + size + 3) & ~3
        if name == "TRAILER!!!":
            return ents
        ents.append((name, mode, body))


def cpio_write(entries):
    out, ino = bytearray(), 1
    for name, mode, body, rmaj, rmin in entries + [("TRAILER!!!", 0, b"", 0, 0)]:
        nb = name.encode() + b"\0"
        nlink = 2 if (mode & 0o170000) == 0o040000 else 1
        hdr = b"070701" + b"".join(b"%08X" % v for v in
              (ino, mode, 0, 0, nlink, 0, len(body), 0, 0, rmaj, rmin, len(nb), 0))
        out += hdr + nb + b"\0" * ((-(110 + len(nb))) % 4) + body + b"\0" * ((-len(body)) % 4)
        ino += 1
    out += b"\0" * ((-len(out)) % 512)
    return bytes(out)


def main():
    src, init_path, dst = sys.argv[1:4]
    d = open(src, "rb").read()
    if d[:8] != b"ANDROID!":
        die("input is not an Android boot image")
    ks, ka, rs, ra, ss, sa, ta, ps, dts, ver = struct.unpack("<10I", d[8:48])
    if ver != 0:
        die("boot image header version %d is not supported (expected 0)" % ver)
    ps = ps or PAGE_FALLBACK
    pg = lambda n: (n + ps - 1) // ps * ps
    ko = ps
    ro = ko + pg(ks)
    so = ro + pg(rs)
    do = so + pg(ss)
    kernel, ramdisk, dt = d[ko:ko + ks], d[ro:ro + rs], d[do:do + dts]
    print("input: kernel %d, ramdisk %d, second %d, dt %d, page %d, addrs k=%#x r=%#x t=%#x" %
          (ks, rs, ss, dts, ps, ka, ra, ta))
    if ss:
        die("input has a second stage (%d bytes), not expected" % ss)

    # ---- raw kernel ----
    if kernel[:2] == b"\x1f\x8b":
        z = zlib.decompressobj(31)
        raw = z.decompress(kernel)
        print("kernel was gzip: %d -> %d bytes (%d bytes of trailing data dropped)" %
              (len(kernel), len(raw), len(z.unused_data)))
        kernel = raw
    if kernel[56:60] != b"ARM\x64":
        print("WARNING: kernel does not carry the arm64 Image magic at offset 56 (first bytes %r)" % kernel[:8])
    # ---- tiny initramfs from the pmOS one ----
    cpio = cpio_read(decompress_stream(ramdisk))
    names = {n: (m, b) for n, m, b in cpio}

    def find(pred, what):
        c = [(n, b) for n, (m, b) in names.items() if (m & 0o170000) == 0o100000 and pred(n) and len(b) > 1000]
        if not c:
            print("pmOS initramfs content:")
            for n, (m, b) in sorted(names.items()):
                print("  %o %8d %s" % (m, len(b), n))
            die("no %s found in the pmOS initramfs" % what)
        return max(c, key=lambda x: len(x[1]))
    bb_name, busybox = find(lambda n: n.split("/")[-1] == "busybox", "busybox")
    ld_name, ldmusl = find(lambda n: n.split("/")[-1].startswith("ld-musl-aarch64"), "musl loader")
    print("using %s (%d bytes) and %s (%d bytes)" % (bb_name, len(busybox), ld_name, len(ldmusl)))
    # the tiny initramfs only carries the musl loader: refuse a busybox that needs any other library
    import os, tempfile
    with tempfile.NamedTemporaryFile(delete=False) as t:
        t.write(busybox)
    try:
        r = subprocess.run(["readelf", "-d", t.name], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        needed = [l.split("[")[1].split("]")[0] for l in r.stdout.decode().splitlines() if "(NEEDED)" in l]
        print("busybox needs:", needed if r.returncode == 0 else "(readelf unavailable)")
        extra = [n for n in needed if not n.startswith(("libc.musl", "ld-musl"))]
        if extra:
            die("busybox needs libraries that the tiny initramfs does not carry: %s" % extra)
    finally:
        os.unlink(t.name)
    init = open(init_path, "rb").read()
    ents = [
        (".", 0o040755, b"", 0, 0),
        ("bin", 0o120777, b"usr/bin", 0, 0),
        ("dev", 0o040755, b"", 0, 0),
        ("etc", 0o040755, b"", 0, 0),
        ("init", 0o100755, init, 0, 0),
        ("lib", 0o120777, b"usr/lib", 0, 0),
        ("proc", 0o040755, b"", 0, 0),
        ("run", 0o040755, b"", 0, 0),
        ("sbin", 0o120777, b"usr/bin", 0, 0),
        ("sys", 0o040755, b"", 0, 0),
        ("sysroot", 0o040755, b"", 0, 0),
        ("tmp", 0o040755, b"", 0, 0),
        ("usr", 0o040755, b"", 0, 0),
        ("usr/bin", 0o040755, b"", 0, 0),
        ("usr/lib", 0o040755, b"", 0, 0),
        ("usr/sbin", 0o040755, b"", 0, 0),
        ("usr/bin/busybox", 0o100755, busybox, 0, 0),
        ("usr/lib/ld-musl-aarch64.so.1", 0o100755, ldmusl, 0, 0),
        ("usr/lib/libc.musl-aarch64.so.1", 0o120777, b"ld-musl-aarch64.so.1", 0, 0),
        ("dev/console", 0o020600, b"", 5, 1),
        ("dev/null", 0o020666, b"", 1, 3),
    ]
    newrd = gzip.compress(cpio_write(ents), 9, mtime=0)

    # ---- assemble ----
    cmd = CMDLINE.encode()
    if len(cmd) >= 512:
        die("command line too long")
    hd = bytearray(d[:ps])
    hd[8:12] = struct.pack("<I", len(kernel))
    hd[16:20] = struct.pack("<I", len(newrd))
    hd[64:64 + 512] = cmd + b"\0" * (512 - len(cmd))
    sha = hashlib.sha1()
    for blob in (kernel, newrd, b"", dt):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    hd[576:608] = sha.digest() + b"\0" * 12
    img = (bytes(hd) + kernel + b"\0" * (pg(len(kernel)) - len(kernel)) +
           newrd + b"\0" * (pg(len(newrd)) - len(newrd)) +
           dt + b"\0" * (pg(len(dt)) - len(dt)) + b"SEANDROIDENFORCE")
    print("output: %d bytes (BOOT partition is %d, %d bytes free)" % (len(img), BOOT_PART, BOOT_PART - len(img)))
    if len(img) > BOOT_PART:
        die("boot image does not fit into the 32 MB BOOT partition (%d bytes too big)" % (len(img) - BOOT_PART))
    open(dst, "wb").write(img)
    print("md5 %s" % hashlib.md5(img).hexdigest())


if __name__ == "__main__":
    main()
