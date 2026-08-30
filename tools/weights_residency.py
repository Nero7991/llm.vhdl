#!/usr/bin/env python3
"""The 9B HBM residency REPORT, over the map in `tools/hbm_map.py`.

    weights_residency.py MANIFEST.json [--desc-base ADDR] [--desc-jobs N]
                         [--policy manifest|allocate-below-host|top-down]
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

  * the manifest's `weights_bytes`, `weights_end` and `free_after_gdn` are what
    its own placements actually give;
  * THE GAP LEDGER: every empty byte between the weight placements is accounted
    for by something the manifest declares -- a `stack_holes` entry, the unused
    tail of a declared lane arena, or a segment declared reserved.  On a v1
    flat manifest only the first of the three exists and this is the old
    `stack_hole_bytes` rule.  See the block above `lane_arenas()` for what that
    rule was, why a v2 lane-striped manifest made it fail for a reason
    unrelated to what it guards, and why the answer was not to widen it;
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


# --------------------------------------------------------- the gap accounting
#
# WHAT THIS REPLACED, AND WHY IT WAS NOT A TOLERANCE.  Until 2026-08-30 the
# `stack_hole_bytes` check was one line:
#
#     holes = sum(b.base - a.end for consecutive placements)
#     if holes != hbm["stack_hole_bytes"]: FAIL
#
# On a v2 lane-striped manifest that FAILS -- MEASURED: `manifest 0, the gaps
# between consecutive placements sum to 2690994176` -- and it fails for a
# reason unrelated to what it guards.  `stack_hole_bytes` is not "the gaps".
# `pack_model_fk33.place()` returns `hole` ONLY for bytes skipped to stop an
# object straddling the 4 GiB stack line, and the striped branch never calls
# `place()` at all, so its value is structurally 0.  The two quantities
# coincide under the FLAT layout for one unstated reason: a bump allocator
# leaves no other gaps.  **The old check agreed with its subject by coincidence
# of geometry on every manifest it had ever seen**, which is this project's
# recorded dominant defect class and is exactly what makes a guard get muted
# the first time a new layout arrives.
#
# WHAT IT IS NOW.  The same question asked properly: **is every empty byte
# between the weight placements ACCOUNTED FOR by something the manifest
# declares?**  Three declarations can account for one:
#
#   1. `hbm.stack_holes` -- a bump-allocator skip at a stack boundary;
#   2. the unused TAIL of a declared lane arena (`hbm.lane_stripe.segments`
#      and `.common`), which is by design and is where the 2.69 GiB went;
#   3. a whole 256 MiB segment listed in `hbm.lane_stripe.reserved_segments`.
#
# Anything else is an unexplained hole, reported with its address and size.
#
# ON A v1 FLAT MANIFEST NOTHING BUT (1) EXISTS, so this reduces to the old rule
# and its output on a flat set is byte-identical -- MEASURED, section 4 of
# `docs/debugging/2026-08-30_tokenstripe-the-tail-and-the-gap-ledger.md`.  It is
# STRICTER than the old rule even there: the old one compared TOTALS, so a
# `stack_holes` entry at the wrong offset, or a `stack_holes` list disagreeing
# with `stack_hole_bytes`, both passed.  Both now fail (teeth rows R12, R13).
#
# WHAT WOULD MAKE THIS FAIL -- the question every guard here has to answer.  A
# piece placed outside the arena its manifest declares (A1); an arena whose
# declared `bytes` is not what its pieces actually occupy, in either direction
# (A2); a piece placed non-contiguously inside its own arena, which makes the
# declared `bytes` a lie (A2); a segment left empty inside the weight span
# without being declared reserved (A3); a `stack_holes` entry moved, resized,
# added or deleted (R7, R12, R13).  MEASURED: 9 kills, teeth table section 6.
#
# WHAT IT DELIBERATELY DOES NOT DO.  It never asks whether an arena is on the
# RIGHT segment for its lane.  That needs `ENG_PORT_MAP` and it is
# `pack_model_fk33.check_lane_stripe()` check 1.  `hbm.lane_stripe.checks` in
# the manifest is that function's PACK-TIME self-report copied in, i.e. a
# claim; nothing here reads it, because a checker that reads another checker's
# recorded verdict has checked nothing.

def lane_arenas(hbm):
    """The declared lane arenas as `(segment, base, capacity, bytes)`, or None
    on a v1 flat manifest that declares none.

    `common` is segment 0 and holds the .mv4i headers plus the F32 blob; the
    rest are one per pseudo-channel.  Returned in ONE list because every rule
    below applies to all of them identically."""
    ls = hbm.get("lane_stripe")
    if not ls:
        return None
    out = []
    c = ls.get("common")
    if c:
        out.append((int(c["segment"]), int(c["base"]), int(c["capacity"]),
                    int(c["bytes"])))
    for x in ls.get("segments", []):
        out.append((int(x["segment"]), int(x["base"]), int(x["capacity"]),
                    int(x["bytes"])))
    return out


def _subtract(span, allowed):
    """The bytes of `span = (lo, hi)` left over after every interval in
    `allowed` is removed.  Returns a list of (lo, hi) residues."""
    lo, hi = span
    res = [(lo, hi)]
    for a, b, _why in allowed:
        nxt = []
        for x, y in res:
            if b <= x or a >= y:
                nxt.append((x, y))
                continue
            if x < a < y:
                nxt.append((x, a))
            if x < b < y:
                nxt.append((b, y))
        res = nxt
        if not res:
            break
    return res


def check_gap_accounting(mani, m, placed, fail):
    """Every empty byte between the first and last weight placement is
    accounted for by a declaration the manifest makes.  See the block above."""
    hbm = m.hbm
    order = sorted(placed, key=lambda r: r.base)
    gaps = [(a.end, b.base) for a, b in zip(order, order[1:]) if b.base > a.end]
    total_gap = sum(b - a for a, b in gaps)

    allowed = []

    # (1) the bump allocator's stack-boundary skips.  The LIST is read, not
    # just its total: the old check read only `stack_hole_bytes`, so a hole
    # declared at the wrong address, and a list disagreeing with its own total,
    # were both invisible.
    hole_list = hbm.get("stack_holes")
    declared = hbm.get("stack_hole_bytes")
    if hole_list is not None:
        for x in hole_list:
            off, nb = int(x["offset"]), int(x["nbytes"])
            allowed.append((off, off + nb,
                            "hbm.stack_holes: %s" % x.get("why", "?")))
        s = sum(int(x["nbytes"]) for x in hole_list)
        if declared is not None and s != int(declared):
            fail(f"stack_hole_bytes: manifest {declared}, its own "
                 f"hbm.stack_holes list sums to {s}")

    arenas = lane_arenas(hbm)
    if arenas is not None:
        ls = hbm["lane_stripe"]
        seg = int(ls["segment_bytes"])
        by_seg = {s: (b, c, n) for s, b, c, n in arenas}

        # A1 CONTAINMENT.  Every placement lies wholly inside one declared
        # arena.  Without this, A2's occupancy sums silently omit whatever
        # landed outside and the whole ledger balances over a hole.
        inside = {s: [] for s in by_seg}
        for r in order:
            s = r.base // seg
            a = by_seg.get(s)
            if a is None or r.base < a[0] or r.end > a[0] + a[1]:
                fail(f"{r.name} at {h(r.base)}..{h(r.end)} is not inside any "
                     f"arena hbm.lane_stripe declares (segment {s})")
                continue
            inside[s].append((r.base, r.end))

        # A2 OCCUPANCY.  `pack_model_fk33.lane_stripe_plan()` writes each
        # arena's `bytes` from `fill[s]`, the bump pointer -- so it is the
        # EXTENT from the arena base, not a sum of piece sizes.  Checked as an
        # extent for that reason, and NOT as strict contiguity: a future
        # geometry whose sub-region size is not a 4 KB multiple would make
        # `take()` pad between pieces, and a contiguity rule would then refuse
        # a correct packing.  An interior hole is not waved through by that
        # choice -- it is a gap between two placements like any other and falls
        # out of the ledger below with its address.  MEASURED on the shipping
        # striped manifest: 0 interior holes across 6,973 placements.
        #
        # This is the rule that makes the tail in (2) a DERIVED number rather
        # than a manifest field compared against itself.
        for s, b, c, n in arenas:
            if not inside[s]:
                fail(f"segment {s} arena declares {n} occupied bytes and no "
                     f"placement is inside it")
                continue
            got = max(y for _x, y in inside[s]) - b
            if got != n:
                fail(f"segment {s} arena declares {n} occupied bytes and its "
                     f"pieces run {got} bytes from {h(b)}")
                continue
            # (2) the unused tail, DERIVED from the placements just walked.
            if c > n:
                allowed.append((b + n, b + c,
                                "the unused tail of the segment %d lane arena"
                                % s))

        # (3) whole segments nothing was placed in.  Declared, or unexplained.
        for s in ls.get("reserved_segments", []):
            allowed.append((int(s) * seg, (int(s) + 1) * seg,
                            "hbm.lane_stripe.reserved_segments"))

    # THE VERDICT: every empty byte between two placements is covered by one of
    # the three declarations above.  Reported per RESIDUE with its address, not
    # as a total: a total says a manifest is inconsistent, an address says
    # where.  The old rule could only ever print a total, which is why its one
    # message on the striped set named 2.69 GiB and pointed at nothing.
    resid = [(x, y) for a, b in gaps for x, y in _subtract((a, b), allowed)]
    unaccounted = sum(y - x for x, y in resid)
    for x, y in resid[:8]:
        fail(f"{y - x} bytes at {h(x)}..{h(y)} are empty and nothing the "
             f"manifest declares accounts for them")
    if len(resid) > 8:
        fail(f"... and {len(resid) - 8} more unaccounted ranges")
    if resid:
        fail(f"the weight placements leave {total_gap} empty bytes, of which "
             f"{total_gap - unaccounted} are accounted for by hbm.stack_holes, "
             f"the declared lane arena tails and hbm.lane_stripe."
             f"reserved_segments, and {unaccounted} are not")


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

    check_gap_accounting(mani, m, placed, fail)

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
    ap.add_argument("--policy",
                    choices=("manifest", "allocate-below-host", "top-down"),
                    default="manifest",
                    help="'manifest' READS hbm.desc_arena_base, the decided mechanism. 'top-down' is "
                         "gen_layer_program.py's HISTORIC default and it "
                         "COLLIDES with the host blocks")
    ap.add_argument("--no-host-blocks", action="store_true",
                    help="do not model the three blocks pl_derive_bases() "
                         "allocates at the top of HBM")
    ap.add_argument("--max-chunk", type=int, default=None,
                    help="pl_open()'s max_chunk, which sets the R_X staging "
                         "span.  Default: hbm.host_max_chunk out of the "
                         "manifest, which pins the cap the arena was placed "
                         "under")
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
