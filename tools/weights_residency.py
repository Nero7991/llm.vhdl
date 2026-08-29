#!/usr/bin/env python3
"""The 9B HBM residency REPORT, over the map in `tools/hbm_map.py`.

    weights_residency.py MANIFEST.json [--desc-base ADDR] [--desc-jobs N]
                         [--policy below-host|top-down]
                         [--no-host-blocks] [--max-chunk N]
                         [--markdown] [--per-tensor]

WHAT THIS IS FOR.  `tools/check_mv4i_set.py` answers "is the packed set on
DISK internally consistent".  It walks the files, re-derives every size from
`pack_int4.packed_layout`, and checks the manifest against the bytes.  It does
NOT answer the question this file exists for, which is:

    is the 8 GiB address space PARTITIONED, with every region a card-side
    consumer needs given a base, a length, and no overlap with any other?

**THE ADDRESS MODEL MOVED OUT OF THIS FILE ON 2026-08-29 (TRACK ADDRARENA).**
It used to carry its own copy: it re-derived `pl_derive_bases()`'s three host
blocks in Python from the strides in `server/fk33_seam.h`, and its own copy of
`gen_layer_program.py`'s arena default.  That made it a FOURTH model of an
address space that already had three, free to drift from the C the moment
anyone edited `pl_backend.c`, and detection without a fix is what it delivered:
it correctly reported the collision, and both producers went on colliding
because neither consulted it.

`tools/hbm_map.py` is now the one model.  `gen_layer_program.py` asks it where
the descriptor arena goes and REFUSES to emit descriptors if the answer
overlaps anything; `pl_check_bases()` in `server/pl_backend.c` gained the
arena as a fourth checked region; and `hbm_map.py --check-c` COMPILES the real
`pl_derive_bases()` and requires it to agree address for address, so the Python
mirror cannot silently drift.

WHAT REMAINS HERE, and it is not nothing: the checks that are about the
MANIFEST'S OWN ARITHMETIC rather than about addresses.

  * the manifest's `weights_bytes`, `weights_end`, `stack_hole_bytes` and
    `free_after_gdn` are what its own placements actually give;
  * `max_context_tokens` is `floor(kv_bytes / kv_bytes_per_token)`;
  * the F32 blob's 177 internal entries are 4 KB aligned, inside the blob, in
    one stack, and their `hbm_offset` is the blob base plus their offset;
  * the per-tensor-kind byte breakdown, and the dropped-tensor accounting.

The geometry checks -- alignment, bounds, the stack line, the declared stack,
and every pairwise overlap across all three allocators -- come from
`hbm_map.HbmMap.check()` and are not restated here.

WHAT IT DOES NOT CHECK.  It never opens a .mv4i file and it never touches the
card.  Sizes, hashes and header bytes are `check_mv4i_set.py`'s job on disk and
`hw/fk33/host/fk33_load_weights.py verify`'s job on the card.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hbm_map as HM              # noqa: E402  THE address space, single copy

HBM_SIZE = HM.HBM_TOP
STACK_BOUNDARY = HM.STACK_LINE
ALIGN = HM.PAGE
DESC_BYTES_PER_JOB = HM.DESC_STRIDE
Region = HM.Region
h = HM.h
gib = HM.gib
stack_of = HM.stack_of


# ------------------------------------------------------------------ checks
#
# ONLY the checks that are about the MANIFEST'S OWN ARITHMETIC.  Alignment,
# bounds, the stack line, the declared stack, and every pairwise overlap live
# in `hbm_map.HbmMap.check()` and are deliberately not restated here: a second
# copy of a check is a second thing to keep in step, and this address space
# already had three of those.

def check_manifest_arithmetic(mani, m, fail):
    """`m` is an `hbm_map.HbmMap`.  Everything below re-derives a summary field
    from the placements the same manifest declares, so a manifest that
    disagrees with itself is caught before anything is loaded."""
    files = mani["files"]
    hbm = m.hbm
    placed = [r for r in m.regions if r.kind in ("mv4i", "f32blob")]
    if not placed:
        fail("no packed tensors in the manifest")
        return

    tot = sum(r.nbytes for r in placed)
    if hbm.get("weights_bytes") is not None and tot != int(hbm["weights_bytes"]):
        fail(f"weights_bytes: manifest {hbm['weights_bytes']}, placements "
             f"sum to {tot}")

    end = max(r.end for r in placed)
    if hbm.get("weights_end") is not None:
        want = (end + ALIGN - 1) & ~(ALIGN - 1)
        if int(hbm["weights_end"]) != want:
            fail(f"weights_end: manifest {hbm['weights_end']}, last placement "
                 f"ends at {end} (4 KB rounded {want})")

    order_p = sorted(placed, key=lambda r: r.base)
    holes = sum(b.base - a.end for a, b in zip(order_p, order_p[1:]))
    if hbm.get("stack_hole_bytes") is not None and holes != int(hbm["stack_hole_bytes"]):
        fail(f"stack_hole_bytes: manifest {hbm['stack_hole_bytes']}, the gaps "
             f"between consecutive placements sum to {holes}")

    # The KV arithmetic is checked against the MANIFEST'S OWN extents, not the
    # shortened ones: the top-anchored charge is this tool's restatement and
    # the manifest cannot be expected to know it.
    per = int(hbm.get("kv_bytes_per_token", 0))
    kv = sum(int(e["nbytes"]) for e in hbm.get("kv_extents", []))
    if per:
        want = kv // per
        if int(hbm.get("max_context_tokens", -1)) != want:
            fail(f"max_context_tokens: manifest {hbm.get('max_context_tokens')}, "
                 f"{kv} bytes / {per} per token = {want}")
    if hbm.get("free_after_gdn") is not None and kv != int(hbm["free_after_gdn"]):
        fail(f"free_after_gdn {hbm['free_after_gdn']} is not the KV extent "
             f"total {kv}")

    # The F32 blob's internal entries.  These never become Regions -- they are
    # sub-ranges of one object -- so hbm_map cannot see them and this is the
    # only place they are checked.
    for e in files:
        if e["kind"] != "f32blob":
            continue
        base, nb = int(e["hbm_offset"]), int(e["nbytes"])
        for x in e.get("entries", []):
            off, xb = int(x["offset"]), int(x["nbytes"])
            if off % ALIGN:
                fail(f"f32 entry {x['name']}: offset {off} is not 4 KB aligned")
            if off + xb > nb:
                fail(f"f32 entry {x['name']}: {off}+{xb} runs past the "
                     f"{nb} byte blob")
            if int(x["hbm_offset"]) != base + off:
                fail(f"f32 entry {x['name']}: hbm_offset {x['hbm_offset']} is "
                     f"not blob base {base} + {off}")
            if stack_of(base + off) != stack_of(base + off + xb - 1):
                fail(f"f32 entry {x['name']} straddles the stack boundary")


# ------------------------------------------------------------------ report

def report(mani, m, markdown, per_tensor):
    files = mani["files"]
    hbm = m.hbm
    print(f"manifest   {mani.get('format')}")
    print(f"source     {mani.get('source_gguf')}")
    print(f"generated  {mani.get('generated')}")
    g = mani.get("geometry", {})
    print(f"geometry   ROWS_IF={g.get('rows_if')} AXI_DW={g.get('axi_dw')} "
          f"BLOCK={g.get('block')} nports_w={g.get('nports_w')} "
          f"n_scale_sub={g.get('n_scale_sub')} "
          f"qkv_segment_pad={g.get('qkv_segment_pad', False)}")
    c = mani.get("counts", {})
    print(f"counts     {c.get('matvec')} matvec + {c.get('f32')} f32 = "
          f"{c.get('tensors')} tensors from {c.get('gguf_tensors')} in the GGUF, "
          f"{c.get('dropped', 0)} dropped")
    for d in mani.get("dropped_tensors", []):
        print(f"  DROPPED  {d['name']}  shape {d['shape_ne']}  "
              f"would have cost {d['bytes_if_placed']} B = "
              f"{gib(d['bytes_if_placed'])}")
    print()

    m.print_report(markdown)

    placed = [r for r in m.regions if r.kind in ("mv4i", "f32blob")]
    tot = sum(r.nbytes for r in placed)
    kv = sum(r.nbytes for r in m.regions if r.kind == "kv")
    per = int(hbm.get("kv_bytes_per_token", 1)) or 1
    print(f"  weights   {tot:,} = {gib(tot)}   "
          f"({100 * tot / m.hbm_top:.2f}% of the device)")
    print(f"  gdn       {int(hbm.get('gdn_state_bytes', 0)):,}")
    print(f"  kv        {kv:,} = {gib(kv)}  ->  {kv // per} tokens of context "
          f"(manifest said {hbm.get('max_context_tokens')} before the "
          f"top-anchored blocks were charged)")
    print(f"  desc      {sum(r.nbytes for r in m.regions if r.kind == 'desc'):,}")
    print(f"  host      {sum(r.nbytes for r in m.regions if r.kind == 'host'):,}")

    if per_tensor:
        print()
        by = {}
        for e in files:
            k = e["tensor"] or e["file"]
            k = k.split(".", 2)[-1] if k.startswith("blk.") else k
            b = by.setdefault(k, [0, 0])
            b[0] += 1
            b[1] += int(e["nbytes"])
        print(f"{'tensor kind':28s} {'n':>4s} {'bytes':>15s}  {'GiB':>8s}")
        for k in sorted(by, key=lambda k: -by[k][1]):
            n, b = by[k]
            print(f"{k:28s} {n:>4d} {b:>15,}  {b / 2**30:8.4f}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest")
    ap.add_argument("--desc-base", type=lambda x: int(x, 0), default=None,
                    help="base of the subsystem A descriptor arena. Default: "
                         "whatever tools/hbm_map.py's --policy gives")
    ap.add_argument("--desc-jobs", type=int, default=311,
                    help="number of A descriptors to reserve space for "
                         "(311 at the 9B token program). 0 removes the arena")
    ap.add_argument("--policy", choices=("below-host", "top-down"),
                    default="below-host",
                    help="how hbm_map places the arena. 'top-down' is "
                         "gen_layer_program.py's HISTORIC default and it "
                         "COLLIDES with the host blocks")
    ap.add_argument("--no-host-blocks", action="store_true",
                    help="do not model the three blocks pl_derive_bases() "
                         "allocates at the top of HBM")
    ap.add_argument("--max-chunk", type=int, default=512,
                    help="pl_open()'s max_chunk, which sets the R_X staging "
                         "span (default 512)")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--per-tensor", action="store_true")
    a = ap.parse_args()

    with open(a.manifest) as f:
        mani = json.load(f)

    m = HM.plan(mani, desc_jobs=a.desc_jobs, desc_base=a.desc_base,
                policy=a.policy, max_chunk=a.max_chunk,
                want_host_blocks=not a.no_host_blocks)

    fails = m.check()                      # geometry, from the ONE model
    check_manifest_arithmetic(mani, m, fails.append)
    report(mani, m, a.markdown, a.per_tensor)

    print()
    if fails:
        for msg in fails:
            print(f"FAIL  {msg}")
        print(f"\n{len(fails)} FAIL")
        return 1
    print("PASS  every region is aligned, in range, in one stack, and disjoint, "
          "and the manifest agrees with its own placements")
    return 0


if __name__ == "__main__":
    sys.exit(main())
