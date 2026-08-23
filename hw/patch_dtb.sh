#!/bin/bash
# hw/patch_dtb.sh -- apply the two device-tree changes and repackage image.ub
# WITHOUT running PetaLinux.
#
# WHY NOT petalinux-build.  It refuses to run: `gcc-multilib` is missing, and
# installing it would REMOVE gcc/g++-aarch64-linux-gnu (they conflict on Ubuntu
# 22.04) -- the very cross-compiler hw/Makefile uses for mv_driver_aarch64, plus
# the Jetson vpi2 cross toolchain. That trade is not worth making silently, so
# the DTB is patched directly instead.
#
# CAVEAT, and it is a real one: this edits the BUILT device tree, so the DTB in
# image.ub is no longer derived from system-user.dtsi by the build. The .dtsi is
# committed and is the source of truth; the next real petalinux-build will
# reproduce this. Until then the two can drift, and anyone changing the .dtsi
# must re-run this or rebuild properly.
#
# Changes applied, matching the committed system-user.dtsi:
#   1. fan cooling-levels 70,70,... -> 60,60,...   (7% -> 6% floor)
#   2. reserved-memory: mv-weights@70000000, 256 MB, no-map
set -e
PLNX=~/GitHub/zcu106-2023.2-axu3eg
MKIMAGE=/mnt/storage/petalinux/2023.2/components/yocto/buildtools/sysroots/x86_64-petalinux-linux/usr/bin/mkimage
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SRC_DTB=$(find "$PLNX/build/tmp/work" -path "*recipe-sysroot/boot/devicetree/system-top.dtb" | head -1)
ITS=$(ls -t "$PLNX"/build/tmp/deploy/images/zynqmp-generic-xczu3eg/fitImage-its-petalinux-image-minimal-*.its | head -1)
[ -f "$SRC_DTB" ] || { echo "no system-top.dtb"; exit 1; }
[ -f "$ITS" ]     || { echo "no .its"; exit 1; }
[ -x "$MKIMAGE" ] || { echo "no mkimage at $MKIMAGE"; exit 1; }

echo "dtb : $SRC_DTB"
echo "its : $(basename "$ITS")"

dtc -I dtb -O dts "$SRC_DTB" > "$WORK/in.dts" 2>/dev/null

python3 - "$WORK/in.dts" "$WORK/out.dts" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()

# 1. fan floor 7% -> 6%.  0x46 = 70 per-mille, 0x3c = 60.
old = "cooling-levels = <0x46 0x46 0x50 0x5a 0x64 0x12c 0x258 0x3e8>;"
new = "cooling-levels = <0x3c 0x3c 0x50 0x5a 0x64 0x12c 0x258 0x3e8>;"
if old not in s:
    if new in s:
        print("  fan floor: already 6%")
    else:
        sys.exit("fan cooling-levels not found and not already patched")
else:
    s = s.replace(old, new, 1)
    print("  fan floor: 7% -> 6%")

# 2. reserved-memory entry, added INSIDE the existing node
anchor = "\treserved-memory {\n\t\t#address-cells = <0x02>;\n\t\t#size-cells = <0x02>;\n\t\tranges;\n"
if "mv-weights@70000000" in s:
    print("  mv-weights: already present")
elif anchor not in s:
    sys.exit("reserved-memory node not found in the expected shape")
else:
    s = s.replace(anchor, anchor +
                  "\n\t\tmv-weights@70000000 {\n"
                  "\t\t\tno-map;\n"
                  "\t\t\treg = <0x00 0x70000000 0x00 0x10000000>;\n"
                  "\t\t};\n", 1)
    print("  mv-weights: reserved 256 MB at 0x70000000")

open(dst, "w").write(s)
PYEOF

dtc -I dts -O dtb -o "$WORK/system-top.dtb" "$WORK/out.dts" 2>/dev/null
echo "  new dtb: $(stat -c%s "$WORK/system-top.dtb") bytes"

# verify by reading the new blob back, not by trusting the edit
dtc -I dtb -O dts "$WORK/system-top.dtb" 2>/dev/null > "$WORK/back.dts"
grep -q "cooling-levels = <0x3c 0x3c" "$WORK/back.dts" || { echo "FAIL: fan"; exit 1; }
grep -q "mv-weights@70000000" "$WORK/back.dts"          || { echo "FAIL: reserve"; exit 1; }
echo "  verified in the recompiled blob"

# repackage the FIT with the patched dtb
# python, not sed: the .its paths carry + and other characters that make a sed
# expression a quoting exercise, and a silently-unmatched pattern here would
# repackage the OLD dtb while reporting success.
#
# EVERY incbin is made absolute, not just the dtb.  dtc resolves /incbin/
# against the directory of the .its FILE, not the cwd, so the kernel's
# relative "linux.bin" cannot be fixed by cd-ing anywhere.
KDIR=$(dirname "$(find "$PLNX/build/tmp/work" -name linux.bin | head -1)")
[ -d "$KDIR" ] || { echo "no linux.bin found"; exit 1; }
python3 - "$ITS" "$WORK/fit.its" "$WORK/system-top.dtb" "$KDIR" <<'PYITS'
import os, re, sys
its, out, dtb, kdir = sys.argv[1:5]
s = open(its).read()
ndtb = [0]

def fix(m):
    path = m.group(2)
    if path.endswith("system-top.dtb"):
        ndtb[0] += 1
        path = dtb
    elif not os.path.isabs(path):
        path = os.path.join(kdir, path)
    return m.group(1) + path + m.group(3)

s2, n = re.subn(r'(data = /incbin/\(")([^"]*)("\);)', fix, s)
if ndtb[0] != 1:
    sys.exit(f"expected exactly one system-top.dtb incbin, found {ndtb[0]}")
for p in re.findall(r'data = /incbin/\("([^"]*)"\);', s2):
    if not os.path.exists(p):
        sys.exit(f"incbin target missing: {p}")
open(out, "w").write(s2)
print(f"  .its: {n} incbin paths absolute, {ndtb[0]} fdt repointed")
PYITS
grep -q "$WORK/system-top.dtb" "$WORK/fit.its" || { echo "FAIL: .its rewrite"; exit 1; }

"$MKIMAGE" -f "$WORK/fit.its" "$WORK/image.ub" > /dev/null
echo "  image.ub: $(stat -c%s "$WORK/image.ub") bytes"

# Verify the PACKAGED artifact, not the intermediate.  Everything above could
# be right and the FIT still carry the old tree if an incbin silently resolved
# elsewhere -- so pull the FDT back out of image.ub and read it.
python3 - "$WORK/image.ub" <<'PYVER'
import os, subprocess, sys, tempfile
d = open(sys.argv[1], "rb").read()
blobs, i = [], 0
while True:
    i = d.find(b"\xd0\x0d\xfe\xed", i + 1)
    if i < 0:
        break
    ln = int.from_bytes(d[i+4:i+8], "big")
    if 10000 < ln < 200000 and i + ln <= len(d):
        blobs.append((i, ln))
if len(blobs) != 1:
    sys.exit(f"expected exactly one FDT in image.ub, found {len(blobs)}")
o, ln = blobs[0]
with tempfile.NamedTemporaryFile(suffix=".dtb", delete=False) as f:
    f.write(d[o:o+ln]); p = f.name
dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", p],
                     capture_output=True, text=True).stdout
os.unlink(p)
if "cooling-levels = <0x3c 0x3c" not in dts:
    sys.exit("packaged image does NOT carry the 6% fan floor")
if "mv-weights@70000000" not in dts:
    sys.exit("packaged image does NOT carry the mv-weights reservation")
print("  packaged image.ub verified: 6% fan floor and mv-weights both present")
PYVER

cp "$WORK/system-top.dtb" "$PLNX/images/linux/system-top-patched.dtb"
cp "$WORK/image.ub" "$PLNX/images/linux/image.ub.patched"
echo
echo "built  $PLNX/images/linux/image.ub.patched"
echo "deploy with:  cp $PLNX/images/linux/image.ub.patched /tftpboot/image.ub"
echo "rollback   :  cp /tftpboot/image.ub.pre-mv-2026-08-23 /tftpboot/image.ub"
