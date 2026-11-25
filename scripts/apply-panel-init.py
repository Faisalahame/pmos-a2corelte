#!/usr/bin/env python3
"""
Touch fix, step 2 (branch display-6.19): replay the Samsung stock TD4101 vendor init in the mainline panel driver.

Finding (stock kernel source, drivers/video/fbdev/exynos/decon_7870/panels/td4101_a2corelte_lcd_ctrl.c + td4101_a2corelte_param.h):
  td4101_init() sends 36 manufacturer commands (B0 B3 B4 B6 B5 B7 BA BB BC BD BE BF C0..CA CC..CF D0 D1 D3 D4 D6 D7 D8 DD DE),
  then 0x53 0x0C, 0x5E 0x30, 0x55 0x03, sleep out, 100 ms. The stock touch driver does nothing to power or reset the chip
  (its power function returns at once), so the touch part of the chip depends on the display side being set up like this.
Mainline 6.19 panel-synaptics-tddi.c tddi_enable() sends only 0x55, 0x53, sleep out, brightness, display on.
Result seen on the phone: touch chip answers on I2C (0x4b) but never shows a register map (no F01 in the PDT), also after
the reset added by scripts/apply-panel-reset.py.

What this script does (edits scripts/build-pmos.sh in the CI checkout, run after apply-panel-reset.py):
  adds a block that patches drivers/gpu/drm/panel/panel-synaptics-tddi.c in the kernel tree:
    1. a helper tddi_td4101_vendor_init() with the 36 stock commands (same order and bytes as the stock param header),
       a 1 ms pause after B4 like stock, and 0x5E 0x30 (CABC minimum) at the end. It only runs for the td4101 (2 lanes).
       Errors do NOT abort the panel enable: they are counted and logged, so the display still comes up.
    2. a call to it at the start of tddi_enable(), before the existing 0x55/0x53 writes and sleep out.
  dmesg shows "pmos-a2corelte: TD4101 vendor init sent (N errors)". N should be 0.
Not copied from stock: the I2C backlight/supply chip (s2dps01) setup, and the stock switch to low-power mode for the first
four commands (mainline sends them the same way as its own sleep out / display on).
"""
import sys

P = "scripts/build-pmos.sh"
s = open(P).read()
if "pmos-a2corelte panel init" in s:
    print("panel init patch already applied")
    sys.exit(0)


def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, "anchor not found exactly once (%d): %r" % (n, old[:80])
    s = s.replace(old, new)


# (command, payload bytes as hex) in the order of td4101_init() in the stock kernel; payload length = bytes after the command byte
CMDS = [
    ("B0", "04"),
    ("B3", "10 00 06"),
    ("B4", "00 01"),
    "PAUSE_1MS",
    ("B6", "32 53 80 00 00 07 86"),
    ("B5", "00 00 00 00"),
    ("B7", "00"),
    ("BA", "07 87 3A 0A 3D 88"),
    ("BB", "00 B4 A0"),
    ("BC", "00 B4 A0"),
    ("BD", "00 B4 A0"),
    ("BE", "04"),
    ("BF", "02 3c 80 09"),
    ("C0", "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00"),
    ("C1", "04 48 01 03 33 08 11 00 11 00 "
           "73 23 23 11 00 00 00 00 00 00 "
           "00 00 00 00 00 00 DF 00 30 00 "
           "01 00 00 00"),
    ("C2", "00 F0 03 C0 0A 04 08 00 24 19 "
           "00 00 00 00 00 00 00 03 00"),
    ("C3", "3D 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "01 01 03 28 00 01 03 01 44 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 F0 00 "
           "00 00 00 00 F0 00 00 00 00 00 "
           "40 20 03"),
    ("C4", "70 01 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 01 01"),
    ("C5", "08 00 00 00 00 70 00 00 2D 41"),
    ("C6", "FA 54 D7 00 00 54 D7 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 80 FA"),
    ("C7", "00 0B 14 22 2F 38 52 65 75 83 "
           "38 43 53 6E 7B 87 8D 96 B8 00 "
           "0B 14 22 2F 38 52 65 75 83 38 "
           "49 59 6E 7B 87 8D 96 B8 00 97 "
           "00 97 00 97 00 97"),
    ("C8", "00 00 00 00 00 FC 00 00 00 00 "
           "00 FC 00 00 00 00 00 FC 00 00 "
           "00 00 00 FC 00 00 00 00 00 FC "
           "00 00 00 00 00 FC 00 00 00 00 "
           "00 FC 00 00 00 00 00 FC 00 00 "
           "00 00 00 FC 00"),
    ("C9", "00 00 00 00 00 FC 00 00 00 00 "
           "00 FC 00 00 00 00 00 FC 00"),
    ("CA", "1D FC FC FC 00 D9 DA 70 00 F0 "
           "26 BA 00 9A 00 02 39 D6 00 EE "
           "00 0D 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00"),
    ("CC", "D2 72 46 42 12 16 1A 1E 00 D0 "
           "70 00 00 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 00 00 00 00 "
           "00 00 00 70 D0 00 1C 18 14 10 "
           "40 44 72 D2 00"),
    ("CD", "D3 03 F2 00 00 00 00 00 00 00 "
           "00 00 00 00 00 00 01 00 00"),
    ("CE", "7D 40 48 56 67 78 88 98 A7 B5 "
           "C3 D1 DE E9 F2 FA FF 3C 00 01 "
           "04 45 00 00"),
    ("CF", "48 10"),
    ("D0", "11 04 59 E3 03 10 10 40 19 08 "
           "99 00 00 00 00 00 00 00"),
    ("D1", "04"),
    ("D3", "BB 3B 33 3B 44 3B 44 3B 00 00 "
           "EC 91 87 23 22 E7 E7 3B BB 4F "
           "D0 3C 10 12 10 00 10"),
    ("D4", "80 04 04 33 00 04 00 00 00 00 "
           "00 00 00 00 00 00 00 00 0A 90 "
           "05 00 64 94"),
    ("D6", "41"),
    ("D7", "F6 FF 03 05 43 24 80 1F C7 1F "
           "1B 00 0F 01 20 08 80 3F 00 78 "
           "00 40 24 15 00 33 02 C0 AF CB "
           "60 30 FC 00 3F 00"),
    ("D8", "00 00 00 00 00 00 00 00"),
    ("DD", "30 06 23 65"),
    ("DE", "00 FF FF 90"),
]

# payload lengths from the stock param header (td4101_a2corelte_param.h), to catch typos while editing this table
LENS = {
    "B0": 1, "B3": 3, "B4": 2, "B6": 7, "B5": 4, "B7": 1, "BA": 6, "BB": 3, "BC": 3, "BD": 3, "BE": 1, "BF": 4,
    "C0": 17, "C1": 34, "C2": 19, "C3": 63, "C4": 40, "C5": 10, "C6": 33, "C7": 46, "C8": 55, "C9": 19, "CA": 43,
    "CC": 45, "CD": 19, "CE": 24, "CF": 2, "D0": 18, "D1": 1, "D3": 27, "D4": 24, "D6": 1, "D7": 36, "D8": 8,
    "DD": 4, "DE": 4,
}
real = [c for c in CMDS if c != "PAUSE_1MS"]
assert len(real) == 36 and [c for c, _ in real] == list(LENS.keys()), "command list does not match the stock list"
for c, p in real:
    n = len(p.split())
    assert n == LENS[c], "command %s has %d payload bytes, stock has %d" % (c, n, LENS[c])


def c_line(cmd, payload):
    b = ["0x" + cmd] + ["0x" + x.upper() for x in payload.split()]
    chunks = [", ".join(b[i:i + 10]) for i in range(0, len(b), 10)]
    return "\tTDDI_V(" + ",\n\t\t".join(chunks) + ");\n"


body = ""
for c in CMDS:
    if c == "PAUSE_1MS":
        body += "\tusleep_range(1000, 1100);\n"
    else:
        body += c_line(*c)
body += "\tTDDI_V(0x5E, 0x30);\t/* CABC minimum, as stock */\n"
NLINES = len(real) + 1  # number of TDDI_V( lines

HELPER = r"""/*
 * pmos-a2corelte: vendor init of the TD4101 panel, copied from the Samsung stock kernel (td4101_a2corelte_lcd_ctrl.c,
 * td4101_a2corelte_param.h). The touch part of the TD4101 does not show a register map without it.
 * Errors are counted and logged but do not stop the panel enable.
 */
static void tddi_td4101_vendor_init(struct tddi_ctx *ctx)
{
	struct mipi_dsi_multi_context v = { .dsi = ctx->dsi };
	int errs = 0;

	if (ctx->data->lanes != 2)	/* td4101 only, the td4300 has 4 lanes */
		return;

#define TDDI_V(...) do { \
	mipi_dsi_dcs_write_seq_multi(&v, __VA_ARGS__); \
	if (v.accum_err) { errs++; v.accum_err = 0; } \
} while (0)

""" + body + r"""#undef TDDI_V

	dev_info(&ctx->dsi->dev, "pmos-a2corelte: TD4101 vendor init sent (%d errors)\n", errs);
}

"""

# the block that goes into the kernel APKBUILD prepare() (same place as the panel reset block, cwd = kernel source dir)
T = "\t"
PERL = r"""perl -0777 -e '
my ($f, $h) = @ARGV;
open(F, "<", $f) or die "cannot open $f\n"; my $s = <F>; close(F);
open(H, "<", $h) or die "cannot open $h\n"; my $c = <H>; close(H);
$s =~ s/(static int tddi_enable\(struct drm_panel \*panel\)\n\{.*?\n)(\tmipi_dsi_)/$1\ttddi_td4101_vendor_init(ctx);\n\n$2/s or die "call anchor not found in tddi_enable\n";
$s =~ s/(static int tddi_enable\(struct drm_panel \*panel\)\n)/$c$1/ or die "tddi_enable anchor not found\n";
print $s;
' "$_tddi" "$_tddi.init" > "$_tddi.new" """.rstrip()

block = (
    T + "# ---- pmos-a2corelte panel init begin ----\n"
    + T + "# TD4101 vendor init from the stock kernel, see scripts/apply-panel-init.py\n"
    + T + "_tddi=drivers/gpu/drm/panel/panel-synaptics-tddi.c\n"
    + T + "cat > \"$_tddi.init\" <<'TDDIINITEOF'\n"
    + HELPER
    + "TDDIINITEOF\n"
    + T + PERL + " || { echo \"pmos-a2corelte panel init: ERROR patching $_tddi failed (anchor not found)\"; return 1; }\n"
    + T + "mv \"$_tddi.new\" \"$_tddi\" && rm -f \"$_tddi.init\"\n"
    + T + "[ \"$(grep -c 'tddi_td4101_vendor_init(ctx);' \"$_tddi\")\" = 1 ] || { echo \"pmos-a2corelte panel init: ERROR call was not added once to $_tddi\"; return 1; }\n"
    + T + "[ \"$(grep -c 'TDDI_V(0x' \"$_tddi\")\" = %d ] || { echo \"pmos-a2corelte panel init: ERROR unexpected number of TDDI_V lines in $_tddi\"; return 1; }\n" % NLINES
    + T + "grep -n 'tddi_td4101_vendor_init\\|TD4101 vendor init' \"$_tddi\"\n"
    + T + "echo \"pmos-a2corelte panel init: TD4101 vendor init (36 stock commands) added to panel-synaptics-tddi.c\"\n"
    + T + "# ---- pmos-a2corelte panel init end ----\n"
)

END = T + "# ---- pmos-a2corelte display backport end ----\n"
rep(END, block + END)

open(P, "w").write(s)
print("scripts/build-pmos.sh patched: TD4101 vendor init (36 stock commands) in the panel driver")
