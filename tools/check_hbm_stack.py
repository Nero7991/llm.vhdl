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

LANE-STRIPED (v2) MANIFESTS: THE RANGES CHECKED MUST BE THE RANGES THAT EXIST.
Under `format` "... v2 lane-striped" a tensor is not one contiguous object.
`hbm_offset` names a 4 KB HEADER and each of the 27 sub-regions is placed in its
own 256 MiB pseudo-channel, listed in the entry's `pieces`.  The v1 arithmetic
`hbm_offset + sub_offset` then names no byte the engine will ever read.

MEASURED 2026-08-30, and it is why this section exists: on the shipping striped
set this program printed `checked 7154 byte ranges ... PASS`, the SAME 7,154 as
on the flat set, of which every sub-region range was fictitious.  It was not
detecting an absence of crossings; it was asking about an address space that
does not exist and getting a plausible answer.  A guard that has never been
shown to discriminate on the thing it guards is decoration.

So on a v2 entry this program checks each PIECE's real range, and adds three
structural rules that no other consumer can state, because it is the only
checker that opens the .mv4i:

  * the pieces tile the file exactly, from 0 to its size ON DISK;
  * the piece cuts are the file's OWN sub-region boundaries -- a 4 KB header
    piece plus one piece per entry of the 0x38 table.  `tools/hbm_map.py`
    cannot check this: it never opens the file;
  * `hbm_offset` is the first piece, and every piece is 4 KB aligned.

The count line names how many entries were striped and how many piece ranges
were read, so a future silent skip is visible in the output rather than
inferred.

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
    n_striped = 0
    n_piece = 0

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
        pcs = e.get("pieces")
        if not os.path.exists(path):
            bad.append((e["file"], base, e["nbytes"], "file missing on disk"))
            continue
        sz = os.path.getsize(path)          # DISK size, never the manifest's
        if sz != e["nbytes"]:
            bad.append((e["file"], base, sz,
                        f"on disk {sz} B, manifest says {e['nbytes']} B"))
        if not pcs:
            # v1 flat: the object IS one range at `base`.
            chk(e["file"], base, sz)
        else:
            # v2 lane-striped: `base` is a 4 KB header and the object is one
            # range PER PIECE.  Checking [base, base+sz) here would be the
            # fictitious range this program used to pass over.
            n_striped += 1
            pos = 0
            for i, x in enumerate(pcs):
                fo, ho, nb = (int(x["file_offset"]), int(x["hbm_offset"]),
                              int(x["nbytes"]))
                tag = x.get("kind", "?")
                if x.get("lane") is not None:
                    tag = f"{tag}{x['lane']:02d}"
                if fo != pos:
                    bad.append((f"{e['file']}:{tag}", ho, nb,
                                f"piece {i} starts at file +{fo}, the pieces "
                                f"before it end at +{pos}"))
                if ho & 0xFFF:
                    bad.append((f"{e['file']}:{tag}", ho, nb,
                                "piece is not 4 KB aligned in HBM"))
                n_piece += 1
                chk(f"{e['file']}:{tag}", ho, nb)
                pos = fo + nb
            if pos != sz:
                bad.append((e["file"], base, sz,
                            f"pieces cover {pos} B, the file is {sz} B on "
                            f"disk"))
            if int(pcs[0]["hbm_offset"]) != base:
                bad.append((e["file"], base, sz,
                            f"hbm_offset is {base} and the first piece is at "
                            f"{pcs[0]['hbm_offset']}"))

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
        if pcs:
            # THE CUTS MUST BE THE FILE'S OWN.  This is the one rule here that
            # no other consumer can state: `tools/hbm_map.py` validates the
            # pieces against the manifest's `nbytes` and never opens the .mv4i,
            # so a manifest that cut the file somewhere other than the header's
            # 0x38 table still tiles, still sums, and still passes there.  The
            # pieces the engine reads are the SUB-REGIONS; a piece boundary
            # anywhere else means the descriptor's base for that sub-region
            # lands mid-piece or in another lane's arena.
            want = [0] + offs                        # header, then each sub
            got = [int(x["file_offset"]) for x in pcs]
            if got != want:
                bad.append((e["file"], base, sz,
                            f"the manifest cuts this file at {got[:6]}... "
                            f"({len(got)} pieces); its own sub-region table "
                            f"cuts it at {want[:6]}... ({len(want)})"))
            elif int(pcs[0]["nbytes"]) != HDR_BYTES:
                bad.append((e["file"], base, sz,
                            f"the first piece is {pcs[0]['nbytes']} B, a "
                            f"header is {HDR_BYTES} B"))
            # The per-sub-region STACK question is already answered above, on
            # each piece's real address.  Re-asking it at `base + o` would be
            # the fictitious range.
            continue
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
    print(f"  format {man.get('format')!r}: {n_striped} of "
          f"{len(man['files'])} entries are LANE-STRIPED, contributing "
          f"{n_piece} piece ranges")
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
