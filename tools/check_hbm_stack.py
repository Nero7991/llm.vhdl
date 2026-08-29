#!/usr/bin/env python3
"""Does any placed object cross the FK33's 4 GiB HBM stack boundary?

    check_hbm_stack.py OUTDIR [--stack-bytes N] [--hbm-bytes N] [-v]

WHY A SEPARATE PROGRAM.  `pack_model_fk33.py` asserts the stack rule while it
allocates, so the allocator and its assertion share one arithmetic and one
belief.  That is exactly the self-consistency this project keeps getting caught
by (CLAUDE.md, "a round trip is not an oracle").  This checker therefore shares
NOTHING with the allocator:

  * it never imports `pack_int4`, so it does not use `packed_layout`;
  * it reads each .mv4i's sub-region base table OUT OF THE FILE'S OWN HEADER
    (spec 6.4: NPORTS_W at 0x1A, scale base at 0x30, n_scale_sub at 0x34, and
    the `nports_w + n_scale_sub` 64-bit sub-region offsets from 0x38), so the
    extents it checks are the ones a consumer would actually read, not the ones
    the packer meant to write;
  * it re-derives each sub-region's LENGTH from the gap to the next base and, for
    the last one, from the file size on disk;
  * it takes the file's base address from the manifest and its length from
    `os.path.getsize`, so a manifest whose `nbytes` lies is caught too.

WHAT IT CHECKS.  For every object -- each .mv4i file, each of its 27
sub-regions, the F32 side blob, each of the 177 tensors inside it, the GDN state
region, and each per-token KV record slot -- the byte range [base, base+len)
must lie inside ONE stack, i.e. `base // STACK == (base+len-1) // STACK`.

WHY IT MATTERS.  An AXI master that reads across the boundary does not fault.
The HBM IP exposes all 32 pseudo-channel segments on every SAXI port when both
global switches are on (MEASURED, docs/2026-08-28_can-27-read-masters-be-served
section 2.1), so the address decodes and the read completes OKAY.  The answer is
arithmetically plausible and wrong, and no descriptor field can detect it.

EXIT 0 = PASS, 1 = at least one crossing (or a structural problem that would
make the crossing check meaningless).  Teeth: run it on a manifest known to
straddle and it must exit 1; a checker never shown to fail has not been shown to
work.
"""

import argparse
import json
import os
import struct
import sys

MAGIC = 0x4D563449          # "MV4I", spec 6.4; restated, not imported
HDR_BYTES = 4096


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", help="directory holding manifest.json")
    ap.add_argument("--stack-bytes", type=int, default=4 * 1024 ** 3)
    ap.add_argument("--hbm-bytes", type=int, default=8 * 1024 ** 3)
    ap.add_argument("--manifest", default=None,
                    help="manifest path, if not OUTDIR/manifest.json")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    S = a.stack_bytes
    mpath = a.manifest or os.path.join(a.outdir, "manifest.json")
    if not os.path.exists(mpath):
        print(f"FAIL no manifest at {mpath}")
        return 1
    man = json.load(open(mpath))

    bad = []
    n_obj = 0

    def chk(label, base, nbytes):
        """One object.  Empty objects are checked as a point, not skipped."""
        nonlocal n_obj
        n_obj += 1
        if nbytes < 0:
            bad.append((label, base, nbytes, "negative length"))
            return
        last = base + max(nbytes, 1) - 1
        if base // S != last // S:
            b = (base // S + 1) * S
            bad.append((label, base, nbytes,
                        f"{base} .. {base+nbytes} crosses {b} "
                        f"(stack {base//S} -> {last//S}); "
                        f"{base + nbytes - b} bytes on the wrong side"))
        if base + nbytes > a.hbm_bytes:
            bad.append((label, base, nbytes, "runs past the end of HBM"))
        if a.verbose:
            print(f"  {label:<58} {base:>13} + {nbytes:<11} stack {base//S}")

    for e in man["files"]:
        path = os.path.join(a.outdir, e["file"])
        base = e["hbm_offset"]
        if not os.path.exists(path):
            bad.append((e["file"], base, e["nbytes"], "file missing on disk"))
            continue
        sz = os.path.getsize(path)          # DISK size, never the manifest's
        if sz != e["nbytes"]:
            bad.append((e["file"], base, sz,
                        f"on disk {sz} B, manifest says {e['nbytes']} B"))
        chk(e["file"], base, sz)

        if e["kind"] == "f32blob":
            for x in e.get("entries", []):
                chk(f"{e['file']}[{x['name']}]", x["hbm_offset"], x["nbytes"])
            continue

        # ---- sub-regions, read out of the file's own header
        with open(path, "rb") as f:
            hdr = f.read(HDR_BYTES)
        if len(hdr) < HDR_BYTES:
            bad.append((e["file"], base, sz, "shorter than one header"))
            continue
        magic, = struct.unpack_from("<I", hdr, 0x00)
        if magic != MAGIC:
            bad.append((e["file"], base, sz,
                        f"header magic {magic:#x}, not {MAGIC:#x}"))
            continue
        nports, = struct.unpack_from("<H", hdr, 0x1A)
        scl_off, nss = struct.unpack_from("<II", hdr, 0x30)
        nsub = nports + nss
        if nsub < 1 or 0x38 + 8 * nsub > HDR_BYTES:
            bad.append((e["file"], base, sz,
                        f"header claims {nports}+{nss} sub-regions, which "
                        f"does not fit the 4 KB header"))
            continue
        offs = [struct.unpack_from("<Q", hdr, 0x38 + 8 * i)[0]
                for i in range(nsub)]
        if offs != sorted(offs) or offs[0] != HDR_BYTES:
            bad.append((e["file"], base, sz,
                        "sub-region base table is not ascending from 0x1000"))
            continue
        if offs[nports] != scl_off:
            bad.append((e["file"], base, sz,
                        f"scale base {scl_off} disagrees with sub-region "
                        f"table entry {offs[nports]}"))
        ends = offs[1:] + [sz]              # length from the NEXT base
        for i, (o, en) in enumerate(zip(offs, ends)):
            tag = f"w{i}" if i < nports else f"s{i - nports}"
            if en <= o:
                bad.append((f"{e['file']}:{tag}", base + o, en - o,
                            "non-positive sub-region length"))
                continue
            chk(f"{e['file']}:{tag}", base + o, en - o)

    # ---- the regions that are not files
    h = man.get("hbm", {})
    if "gdn_state_base" in h:
        chk("GDN state region", h["gdn_state_base"], h["gdn_state_bytes"])

    kvb = h.get("kv_bytes_per_token")
    if kvb:
        ex = h.get("kv_extents")
        if ex is None:
            # A manifest that predates per-stack extents: reconstruct the ONE
            # region it implied and check its records, which is the check that
            # manifest never had.
            ex = [dict(base=h["kv_base"],
                       nbytes=a.hbm_bytes - h["kv_base"])]
        for x in ex:
            n = x["nbytes"] // kvb
            if n:                            # first and last record only: the
                chk("KV record[0]", x["base"], kvb)          # interior cannot
                chk(f"KV record[{n-1}]",                     # cross if these
                    x["base"] + (n - 1) * kvb, kvb)          # two do not
            chk("KV extent", x["base"], x["nbytes"] - x["nbytes"] % kvb)

    print(f"checked {n_obj} byte ranges against a {S} B stack boundary "
          f"in {mpath}")
    if bad:
        print(f"FAIL {len(bad)} range(s) cross a stack boundary or are "
              f"structurally wrong:")
        for label, base, n, why in bad:
            print(f"  {label}: {why}")
        return 1
    print("PASS no range crosses a stack boundary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
