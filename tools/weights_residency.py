#!/usr/bin/env python3
"""The 9B HBM residency map, computed from a load manifest and CHECKED.

    weights_residency.py MANIFEST.json [--desc-base ADDR] [--desc-jobs N]
                         [--no-host-blocks] [--max-chunk N]
                         [--markdown] [--per-tensor]

WHAT THIS IS FOR.  `tools/check_mv4i_set.py` answers "is the packed set on
DISK internally consistent".  It walks the files, re-derives every size from
`pack_int4.packed_layout`, and checks the manifest against the bytes.  It does
NOT answer the question this file exists for, which is:

    is the 8 GiB address space PARTITIONED, with every region a card-side
    consumer needs given a base, a length, and no overlap with any other?

THREE ALLOCATORS SHARE THIS ADDRESS SPACE AND NONE OF THEM CAN SEE THE OTHER
TWO.

  1. `tools/pack_model_fk33.py` places the 249 packed tensors and the F32 side
     blob upward from 0, then declares the GDN state and calls everything left
     the KV arena.  It writes all of that into `manifest.json`.
  2. `tools/gen_layer_program.py` places the subsystem A descriptors.  Its own
     comment says why it has to: "Nothing in the manifest reserves descriptor
     space.  Take it from the TOP of HBM, aligned down, and state the cost."
  3. `server/pl_backend.c::pl_derive_bases()` places the host's three blocks --
     R_X staging, the logits writeback, and the D program -- also top-down from
     the top of HBM.  `pl_check_bases()` checks those three against each other
     and against the weight image's `reserved_end`, and it has no concept of
     (2); (2) has no concept of (3).

Two of the three anchor at the same end of the device, so this file models all
three in ONE picture, which is the only place the collision is visible.

WHAT IT CHECKS.  Every finding is a FAIL and the exit code is non-zero if
there is one.

  * every placed object is 4 KB aligned and inside the 8 GiB map;
  * no two regions overlap -- packed tensors, F32 blob, GDN state, descriptor
    arena and host blocks alike;
  * no placed object CONTAINS the 0x1_0000_0000 stack boundary strictly
    inside it, and each object's declared `stack` is the stack it is really
    in (the straddle rule of pack_model_fk33.py, re-derived here from the
    addresses rather than trusted from the field);
  * the manifest's own `weights_bytes`, `weights_end`, `stack_hole_bytes` and
    `free_after_gdn` are what the placements actually give;
  * `max_context_tokens` is `floor(kv_bytes / kv_bytes_per_token)`;
  * the F32 blob's 177 internal entries are 4 KB aligned, inside the blob, and
    their `hbm_offset` is the blob's base plus their offset.

THE KV ARENA IS A CHARGE, NOT A COLLISION.  It is DEFINED as everything from
the end of the GDN state to the end of the device, so every top-anchored
reservation overlaps it by construction and reporting that as a fault would be
noise.  Instead the arena is SHORTENED to the lowest top-anchored base and the
restated `max_context_tokens` is printed next to the manifest's.  An overlap
between two top-anchored regions is a different thing and stays a FAIL.

`--desc-base` moves the descriptor arena to check a proposed fix; `--desc-jobs
0` removes it, which is the "A descriptors live in host memory" arrangement;
`--no-host-blocks` removes (3), and `--max-chunk` is the one parameter of (3)
that is not inferable from the manifest.

WHAT IT DOES NOT CHECK.  It never opens a .mv4i file and it never touches the
card.  Sizes, hashes and header bytes are `check_mv4i_set.py`'s job on disk and
`hw/fk33/host/fk33_load_weights.py verify`'s job on the card.  This file is
about ADDRESSES and nothing else, which is why it runs in under a second on a
manifest alone and can be run before the multi-GB set is anywhere near the
machine.
"""

import argparse
import json
import sys

HBM_SIZE = 8 * 1024 ** 3
STACK_BYTES = 4 * 1024 ** 3
STACK_BOUNDARY = STACK_BYTES
ALIGN = 4096
DESC_BYTES_PER_JOB = 512          # gen_layer_program.py's own figure


# ------------------------------------------------------------------ helpers

def h(n):
    return f"{n:#_x}"


def gib(n):
    return f"{n / 2**30:.4f} GiB"


class Region:
    """A named half-open byte range [base, base+nbytes) in the HBM map."""

    __slots__ = ("name", "base", "nbytes", "kind", "stack_field")

    def __init__(self, name, base, nbytes, kind, stack_field=None):
        self.name, self.base, self.nbytes = name, base, nbytes
        self.kind, self.stack_field = kind, stack_field

    @property
    def end(self):
        return self.base + self.nbytes

    def __repr__(self):
        return f"<{self.name} {h(self.base)}..{h(self.end)}>"


def stack_of(addr):
    return 0 if addr < STACK_BOUNDARY else 1


# ------------------------------------------------------------------ the map

def build(mani, desc_base=None, desc_jobs=None):
    """Return (regions, hbm, notes).  Pure: no file or device access."""
    hbm = mani.get("hbm", {})
    files = mani["files"]
    regions = []

    for e in files:
        regions.append(Region(e["file"], int(e["hbm_offset"]), int(e["nbytes"]),
                              e["kind"], e.get("stack")))

    if hbm.get("gdn_state_bytes"):
        regions.append(Region("<gdn recurrent state>",
                              int(hbm["gdn_state_base"]),
                              int(hbm["gdn_state_bytes"]), "gdn",
                              hbm.get("gdn_state_stack")))

    for i, ext in enumerate(hbm.get("kv_extents", [])):
        regions.append(Region(f"<kv arena {i}>", int(ext["base"]),
                              int(ext["nbytes"]), "kv", ext.get("stack")))

    notes = []
    return regions, hbm, notes


def add_host_blocks(regions, notes, n_embd, n_vocab, max_chunk):
    """The three blocks `server/pl_backend.c::pl_derive_bases()` allocates.

    Re-derived here from `server/fk33_seam.h`'s strides rather than read from
    anywhere, because the point is to place them in the SAME picture as the
    descriptor arena, and nothing today does.  `pl_check_bases()` checks these
    three against each other and against the weight image's `reserved_end`; it
    has no concept of a subsystem A descriptor arena, and
    `gen_layer_program.py` has no concept of these.  Both allocate top-down
    from the top of HBM.
    """
    def rup(v, a):
        return (v + a - 1) // a * a

    def adown(v, a):
        return v // a * a

    ALN = 64                                    # FK33_BLOCK_ALIGN
    x_stride = rup(16 + 2 * n_embd, ALN)        # fk33_x_stride
    l_stride = rup(16 + 4 * n_vocab, ALN)       # fk33_l_stride
    x_span, l_span, desc_span = x_stride * max_chunk, l_stride, 4096
    desc_ptr = adown(adown(HBM_SIZE, ALIGN) - desc_span, ALIGN)
    l_base = adown(desc_ptr - l_span, ALIGN)
    x_base = adown(l_base - x_span, ALIGN)
    regions.append(Region("<host R_X staging>", x_base, x_span, "host"))
    regions.append(Region("<host logits writeback>", l_base, l_span, "host"))
    regions.append(Region("<host D program>", desc_ptr, desc_span, "host"))
    notes.append(f"host blocks re-derived from pl_derive_bases() at n_embd="
                 f"{n_embd} n_vocab={n_vocab} max_chunk={max_chunk}: "
                 f"{HBM_SIZE - x_base:,} B from {h(x_base)} to the top")
    return regions


def add_desc_arena(regions, notes, desc_base, desc_jobs):
    if desc_jobs:
        need = DESC_BYTES_PER_JOB * desc_jobs
        if desc_base is None:
            desc_base = (HBM_SIZE - need) & ~(ALIGN - 1)
            notes.append(
                f"descriptor arena base not given; using gen_layer_program.py's "
                f"default, (8 GiB - {need}) rounded down to 4 KB = {h(desc_base)}")
        regions.append(Region("<A descriptor arena>", desc_base,
                              HBM_SIZE - desc_base if desc_base + need > HBM_SIZE
                              else need, "desc", stack_of(desc_base)))
    return regions


def carve_kv(regions, notes, hbm):
    """The KV arena is DEFINED as everything from the end of the GDN state to
    the end of the device, so anything anchored at the top of HBM overlaps it
    by construction.  That is a CAPACITY CHARGE, not a collision: shrink the
    arena to the lowest top-anchored base and restate max_context.  A collision
    between two top-anchored regions is a different thing entirely and stays a
    FAIL.

    Returns (kv_bytes_after, tokens_after, charged_bytes, charged_tokens)."""
    top = [r for r in regions if r.kind in ("host", "desc")]
    per = int(hbm.get("kv_bytes_per_token", 0)) or 1
    before = sum(r.nbytes for r in regions if r.kind == "kv")
    charged = 0
    if top:
        floor_ = min(r.base for r in top)
        for r in regions:
            if r.kind == "kv" and r.end > floor_:
                cut = r.end - max(r.base, floor_)
                charged += cut
                r.nbytes = max(0, r.nbytes - cut)
        notes.append(f"KV arena shortened to {h(floor_)} by the top-anchored "
                     f"reservations: {charged:,} B = {charged // per} tokens")
    after = sum(r.nbytes for r in regions if r.kind == "kv")
    return before, after, charged, charged // per


# ------------------------------------------------------------------ checks

def check(mani, regions, hbm, fail):
    files = mani["files"]

    # ---- per-object: alignment, bounds, stack straddle, declared stack
    for r in regions:
        if r.base % ALIGN:
            fail(f"{r.name}: base {h(r.base)} is not 4 KB aligned")
        if r.base < 0 or r.end > HBM_SIZE:
            fail(f"{r.name}: {h(r.base)}..{h(r.end)} is outside the 8 GiB map")
        if r.nbytes <= 0:
            fail(f"{r.name}: nbytes {r.nbytes} is not positive")
        if r.base < STACK_BOUNDARY < r.end:
            fail(f"{r.name}: {h(r.base)}..{h(r.end)} CONTAINS the stack "
                 f"boundary {h(STACK_BOUNDARY)}; an out-of-stack read does not "
                 f"fault, it returns the wrong bytes and reports success")
        if r.stack_field is not None and stack_of(r.base) != r.stack_field:
            fail(f"{r.name}: manifest says stack {r.stack_field}, base "
                 f"{h(r.base)} is in stack {stack_of(r.base)}")

    # ---- pairwise overlap, over EVERY region and not only the packed files
    order = sorted(regions, key=lambda r: (r.base, r.end))
    for a, b in zip(order, order[1:]):
        if b.base < a.end:
            fail(f"OVERLAP: {a.name} {h(a.base)}..{h(a.end)} and "
                 f"{b.name} {h(b.base)}..{h(b.end)} share "
                 f"{a.end - b.base} bytes")

    # ---- the manifest's own totals, re-derived from the placements
    placed = [r for r in regions if r.kind in ("mv4i", "f32blob")]
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

    holes = 0
    order_p = sorted(placed, key=lambda r: r.base)
    for a, b in zip(order_p, order_p[1:]):
        holes += b.base - a.end
    if hbm.get("stack_hole_bytes") is not None and holes != int(hbm["stack_hole_bytes"]):
        fail(f"stack_hole_bytes: manifest {hbm['stack_hole_bytes']}, the gaps "
             f"between consecutive placements sum to {holes}")

    # ---- KV arithmetic
    per = int(hbm.get("kv_bytes_per_token", 0))
    kv = sum(int(e["nbytes"]) for e in hbm.get("kv_extents", []))   # manifest's
    if per:
        want = kv // per
        if int(hbm.get("max_context_tokens", -1)) != want:
            fail(f"max_context_tokens: manifest {hbm.get('max_context_tokens')}, "
                 f"{kv} bytes / {per} per token = {want}")
    if hbm.get("free_after_gdn") is not None and kv != int(hbm["free_after_gdn"]):
        fail(f"free_after_gdn {hbm['free_after_gdn']} is not the KV extent "
             f"total {kv}")

    # ---- the F32 blob's internal entries
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

def report(mani, regions, hbm, notes, markdown, per_tensor):
    files = mani["files"]
    placed = [r for r in regions if r.kind in ("mv4i", "f32blob")]
    tot = sum(r.nbytes for r in placed)
    kv = sum(r.nbytes for r in regions if r.kind == "kv")
    gdn = int(hbm.get("gdn_state_bytes", 0))
    desc = sum(r.nbytes for r in regions if r.kind == "desc")
    host = sum(r.nbytes for r in regions if r.kind == "host")
    holes = 0
    order_p = sorted(placed, key=lambda r: r.base)
    for a, b in zip(order_p, order_p[1:]):
        holes += b.base - a.end

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

    rows = [
        ("packed weights + F32 blob", order_p[0].base, tot,
         f"{len(placed)} objects, {holes} B of stack-boundary hole between them"),
        ("GDN recurrent state", int(hbm.get("gdn_state_base", 0)), gdn,
         f"stack {hbm.get('gdn_state_stack')}"),
    ]
    per = int(hbm.get("kv_bytes_per_token", 1)) or 1
    for r in regions:
        if r.kind != "kv":
            continue
        rows.append((r.name.strip("<>"), r.base, r.nbytes,
                     f"{r.nbytes // per} tokens at {per} B/token after the "
                     f"top-anchored charge"))
    for r in regions:
        if r.kind == "desc":
            rows.append(("A descriptor arena", r.base, r.nbytes,
                         "gen_layer_program.py, NOT reserved by the manifest"))
    for r in regions:
        if r.kind == "host":
            rows.append((r.name.strip("<>"), r.base, r.nbytes,
                         "pl_derive_bases(), NOT reserved by the manifest"))

    rows.sort(key=lambda r: r[1])
    if markdown:
        print("| region | base | end | bytes | GiB | note |")
        print("|---|---|---|---|---|---|")
        for n, b, nb, note in rows:
            print(f"| {n} | `{h(b)}` | `{h(b + nb)}` | {nb:,} | "
                  f"{nb / 2**30:.4f} | {note} |")
    else:
        print(f"{'region':28s} {'base':>14s} {'end':>14s} "
              f"{'bytes':>15s}  {'GiB':>8s}  note")
        for n, b, nb, note in rows:
            print(f"{n:28s} {h(b):>14s} {h(b + nb):>14s} {nb:>15,}  "
                  f"{nb / 2**30:8.4f}  {note}")

    print()
    used = tot + holes + gdn + kv + desc + host
    print(f"device      {HBM_SIZE:,} B = {gib(HBM_SIZE)}")
    print(f"accounted   {used:,} B = {gib(used)}")
    print(f"unaccounted {HBM_SIZE - used:,} B = {gib(HBM_SIZE - used)}")
    print(f"  weights   {tot:,} = {gib(tot)}   ({100 * tot / HBM_SIZE:.2f}% of the device)")
    print(f"  holes     {holes:,}")
    print(f"  gdn       {gdn:,}")
    print(f"  kv        {kv:,} = {gib(kv)}  ->  {kv // per} tokens of "
          f"context (manifest said {hbm.get('max_context_tokens')} before "
          f"the top-anchored blocks were charged)")
    print(f"  desc      {desc:,}")
    print(f"  host      {host:,}")
    for n in notes:
        print(f"note: {n}")

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
                         "gen_layer_program.py's own default, the top of HBM")
    ap.add_argument("--desc-jobs", type=int, default=311,
                    help="number of A descriptors to reserve space for "
                         "(311 at the 9B token program). 0 removes the arena")
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

    regions, hbm, notes = build(mani)
    add_desc_arena(regions, notes, a.desc_base, a.desc_jobs)
    if not a.no_host_blocks:
        lm = next((e for e in mani["files"] if e.get("tensor") == "output.weight"),
                  None)
        if lm is None:
            notes.append("no output.weight in the manifest, so n_vocab/n_embd "
                         "could not be inferred; host blocks NOT modelled")
        else:
            add_host_blocks(regions, notes, int(lm["K"]), int(lm["M"]),
                            a.max_chunk)
    carve_kv(regions, notes, hbm)
    fails = []
    check(mani, regions, hbm, fails.append)
    report(mani, regions, hbm, notes, a.markdown, a.per_tensor)

    print()
    if fails:
        for m in fails:
            print(f"FAIL  {m}")
        print(f"\n{len(fails)} FAIL")
        return 1
    print("PASS  every region is aligned, in range, in one stack, and disjoint")
    return 0


if __name__ == "__main__":
    sys.exit(main())
