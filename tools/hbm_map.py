#!/usr/bin/env python3
"""THE 8 GiB HBM ADDRESS SPACE, IN ONE PLACE, WITH A CHECK THAT BITES.

    hbm_map.py MANIFEST.json [--desc-jobs N] [--desc-base ADDR]
               [--policy below-host|top-down] [--max-chunk N]
               [--no-host-blocks] [--json] [--markdown] [--check-c]
               [--emit-manifest-hbm]

WHY THIS FILE EXISTS.  On 2026-08-29 TRACK WEIGHTS measured that THREE
allocators share this device and none of them can see the other two, and that
two of them anchor at the same end:

  1. `tools/pack_model_fk33.py` places the 249 packed tensors and the F32 side
     blob upward from 0, declares the GDN state, and calls the remainder the KV
     arena.  It writes all of that into `manifest.json`.
  2. `tools/gen_layer_program.py` places the subsystem A descriptor arena.  Its
     own comment says why it must: "Nothing in the manifest reserves descriptor
     space.  Take it from the TOP of HBM, aligned down, and state the cost."
  3. `server/pl_backend.c::pl_derive_bases()` places the host's three blocks --
     R_X staging, the logits writeback, and the D program -- ALSO top-down from
     the top of HBM.

(2) and (3) COLLIDE at the shipping default, MEASURED at HEAD 9d7a9e5 on
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`:

    A descriptor arena     0x1_FFFD_9000 .. 0x1_FFFF_FE00   159,232 B
    host logits writeback  0x1_FFF0_C000 .. 0x1_FFFF_E840   993,344 B  -153,664
    host D program         0x1_FFFF_F000 .. 0x2_0000_0000     4,096 B  -  3,584

153,664 B of the logits writeback is 38,416 float32 logit slots, the top 15.47%
of the 248,320-entry vocabulary.  Whichever master writes last wins, and the
symptom is a WRONG TOKEN, silently.

THE POINT OF THIS FILE IS NOT TO DETECT THAT ONCE.  `tools/weights_residency.py`
already did, and a detector is not a fix: it re-derived (3) in Python from the
strides in `server/fk33_seam.h`, so it was a FOURTH model of the same address
space, free to drift from the C the moment anyone edited `pl_derive_bases()`.

So this module is the ONE model, and everything else CONSULTS it:

  * `tools/gen_layer_program.py` asks it where the descriptor arena goes and
    REFUSES to emit descriptors if the answer overlaps anything.  A producer
    that cannot emit a colliding arena cannot reintroduce the defect.
  * `tools/weights_residency.py` is a report over this map plus the
    manifest-arithmetic checks that are its own.
  * `hw/fk33/host/fk33_load_weights.py` preflights against it before it writes
    a byte to the device.
  * `--check-c` COMPILES AND RUNS the real `pl_derive_bases()` out of
    `server/pl_backend.c` and requires it to agree address for address.  That
    is the only thing here that is evidence rather than assertion: two Python
    copies agreeing would prove nothing, and this project has a recorded case
    (TRACK SCHED-FIX) of a wrong constant surviving precisely because "the two
    generators agreed with each other".

CONSTANTS ARE SCRAPED, NOT RESTATED.  `FK33_BLOCK_ALIGN`, `FK33_SEAM_HDR_BYTES`,
`FK33_HBM_TOP` and `FK33_HBM_STACK_LINE` are read out of `server/fk33_seam.h`
at import, and a scrape that stops matching is a hard failure rather than a
silent default.  `tools/gen_layer_program.py` set that precedent for the VHDL
nports values after a literal copy of a wrong number agreed with the wrong
original.

THE ARENA POLICY IS INTERIM AND IS OREN'S DECISION, NOT THIS FILE'S.
`--policy below-host` places the arena in the first 4 KB-aligned block below the
host's R_X staging.  At the 9B shape that is 0x1_FFAD_D000, which is the address
TRACK WEIGHTS measured as making the map disjoint.  MEASURED cost against the
colliding placement: 2 tokens of KV context, 61,231 -> 61,229 (TRACK WEIGHTS
said 3; the arithmetic is in the ADDRARENA write-up).  It is a DERIVATION, not a constant, so it moves when the shape moves.
It is still interim: which allocator owns the top of HBM, and whether the arena
is declared in the manifest (option a) or allocated by `pl_derive_bases()`
(option b), is a decision that has been put to Oren and is not made here.
`--policy top-down` reproduces the historic colliding placement, on purpose, so
the check can be shown going red.

WHAT THIS FILE DOES NOT DO.  It never opens a `.mv4i` file, never hashes a
payload, and never touches the card.  Bytes on disk are `check_mv4i_set.py`'s
job; bytes on the device are `fk33_load_weights.py verify`'s.  This is about
ADDRESSES and nothing else.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SEAM_H = os.path.join(REPO, "server", "fk33_seam.h")

if HERE not in sys.path:
    sys.path.insert(0, HERE)


# ------------------------------------------------------- scraped constants

def _scrape_seam_h(names, path=SEAM_H):
    """Read `#define NAME <integer>` out of server/fk33_seam.h.

    A restatement here would be a second copy of exactly the number that this
    file exists to keep single.  A missing or unparseable define is a hard
    failure: a default would be the defect with a different address."""
    try:
        with open(path) as f:
            txt = f.read()
    except OSError as e:
        raise SystemExit("hbm_map: cannot read %s: %s\n"
                         "  The HBM constants are scraped from it rather than "
                         "restated here." % (path, e))
    out = {}
    for n in names:
        m = re.search(r"^#define\s+%s\s+(0x[0-9A-Fa-f]+|\d+)[uU]*[lL]*\s*(?:/\*|//|$)"
                      % re.escape(n), txt, re.M)
        if not m:
            raise SystemExit(
                "hbm_map: %s is not defined in %s in a form this scrape "
                "recognises.  Fix the pattern rather than defaulting: a "
                "default is how the address space got three models."
                % (n, path))
        out[n] = int(m.group(1), 0)
    return out


_C = _scrape_seam_h(["FK33_BLOCK_ALIGN", "FK33_SEAM_HDR_BYTES",
                     "FK33_HBM_TOP", "FK33_HBM_STACK_LINE"])

BLOCK_ALIGN = _C["FK33_BLOCK_ALIGN"]
SEAM_HDR_BYTES = _C["FK33_SEAM_HDR_BYTES"]
HBM_TOP = _C["FK33_HBM_TOP"]
STACK_LINE = _C["FK33_HBM_STACK_LINE"]
PAGE = 4096                       # pl_derive_bases()'s own page granularity


def _desc_stride():
    """Bytes one subsystem A descriptor occupies in the arena.

    `tools/gen_layer_program.py` advances by
    `ceil(desc_bytes / align) * align` with `align = desc_maxb * axi_dw/8`,
    and sizes the arena at that same figure per job.  Imported from
    `gen_mv4i_desc.FK33` so the two cannot disagree."""
    try:
        import gen_mv4i_desc as G
    except ImportError:
        return 512
    b = G.FK33
    return int(b["desc_maxb"]) * (int(b["axi_dw"]) // 8)


DESC_STRIDE = _desc_stride()


# ------------------------------------------------------------------ helpers

def h(n):
    return f"{n:#_x}"


def gib(n):
    return f"{n / 2**30:.4f} GiB"


def align_up(v, a):
    return (v + a - 1) // a * a


def align_down(v, a):
    return v // a * a


def stack_of(addr):
    return 0 if addr < STACK_LINE else 1


class Region:
    """A named half-open byte range [base, base+nbytes), and WHO placed it.

    `owner` is load-bearing.  Every collision this project has had in this
    address space was between two allocators, so a region that cannot name its
    allocator cannot be argued about."""

    __slots__ = ("name", "base", "nbytes", "kind", "owner", "stack_field")

    def __init__(self, name, base, nbytes, kind, owner, stack_field=None):
        self.name, self.base, self.nbytes = name, int(base), int(nbytes)
        self.kind, self.owner, self.stack_field = kind, owner, stack_field

    @property
    def end(self):
        return self.base + self.nbytes

    def __repr__(self):
        return f"<{self.name} {h(self.base)}..{h(self.end)} by {self.owner}>"


# ------------------------------------------------------------- the producers
#
# One function per allocator.  Each one is the ONLY place its addresses are
# computed, and `--check-c` proves the second one still agrees with the C.

def manifest_regions(mani):
    """Allocator 1: `tools/pack_model_fk33.py`, read back out of its manifest.

    Read, never re-derived: the packer's placement IS the ground truth for the
    weight image, and a second derivation of it here would be a claim, not a
    check.  What IS checked (in `check_map`) is that the manifest's own
    summary fields agree with its own placements."""
    hbm = mani.get("hbm", {})
    out = []
    for e in mani["files"]:
        out.append(Region(e["file"], e["hbm_offset"], e["nbytes"], e["kind"],
                          "pack_model_fk33.py", e.get("stack")))
    if hbm.get("gdn_state_bytes"):
        out.append(Region("<gdn recurrent state>", hbm["gdn_state_base"],
                          hbm["gdn_state_bytes"], "gdn",
                          "pack_model_fk33.py", hbm.get("gdn_state_stack")))
    for i, ext in enumerate(hbm.get("kv_extents", [])):
        out.append(Region(f"<kv arena {i}>", ext["base"], ext["nbytes"], "kv",
                          "pack_model_fk33.py", ext.get("stack")))
    return out


def host_blocks(n_embd, n_vocab, max_chunk, hbm_top=None):
    """Allocator 3: `server/pl_backend.c::pl_derive_bases()`, mirrored.

    A MIRROR IS NOT EVIDENCE.  This is arithmetic in Python that claims to
    equal arithmetic in C, and the claim is worth exactly as much as the test
    that checks it: `check_against_c()` compiles `server/pl_backend.c` and
    requires every address to match.  Run it, do not trust this.

    Returns (regions, dict of the raw numbers)."""
    top = HBM_TOP if hbm_top is None else int(hbm_top)
    x_stride = align_up(SEAM_HDR_BYTES + 2 * n_embd, BLOCK_ALIGN)
    l_stride = align_up(SEAM_HDR_BYTES + 4 * n_vocab, BLOCK_ALIGN)
    x_span = x_stride * max_chunk
    l_span = l_stride
    desc_span = PAGE
    desc_ptr = align_down(align_down(top, PAGE) - desc_span, PAGE)
    l_base = align_down(desc_ptr - l_span, PAGE)
    x_base = align_down(l_base - x_span, PAGE)
    regs = [
        Region("<host R_X staging>", x_base, x_span, "host", "pl_derive_bases()"),
        Region("<host logits writeback>", l_base, l_span, "host",
               "pl_derive_bases()"),
        Region("<host D program>", desc_ptr, desc_span, "host",
               "pl_derive_bases()"),
    ]
    raw = dict(x_base=x_base, x_span=x_span, l_base=l_base, l_span=l_span,
               desc_ptr=desc_ptr, desc_span=desc_span, hbm_top=top)
    return regs, raw


def desc_arena(n_jobs, base=None, policy="below-host", host_floor=None,
               stride=None, strict=True):
    """Allocator 2: `tools/gen_layer_program.py`'s subsystem A descriptors.

    `policy`:
      below-host   the first 4 KB-aligned block below `host_floor` (which is
                   pl_derive_bases()'s x_base).  INTERIM -- see the module
                   docstring; it is a derivation, but WHICH allocator owns the
                   top of HBM is Oren's decision, not this file's.
      top-down     `(hbm_top - need) & ~0xFFF`, the historic placement.  It
                   COLLIDES with the host blocks at the 9B shape and is kept
                   so the check can be shown going red.

    An explicit `base` overrides the policy and is checked like any other."""
    if not n_jobs:
        return [], None
    stride = DESC_STRIDE if stride is None else stride
    need = align_up(stride * n_jobs, PAGE)
    if base is None:
        if policy == "top-down":
            base = align_down(HBM_TOP - stride * n_jobs, PAGE)
        elif policy == "below-host":
            if host_floor is None:
                # NO HOST BLOCKS MEANS NO FLOOR TO SIT UNDER.  A producer that
                # is about to emit descriptors must not guess (strict=True, it
                # raises); an auditor over a manifest that carries no
                # `output.weight` -- the loader's synthetic selfcheck images do
                # not -- should report the gap and carry on, because a tool
                # that refuses to run is a tool nobody runs.
                if strict:
                    raise SystemExit(
                        "hbm_map: --policy below-host needs the host blocks, "
                        "and they were not modelled.  Placing the arena "
                        "without them is exactly the blindness this file "
                        "exists to remove; pass --desc-base to say where it "
                        "goes instead.")
                return [], None
            base = align_down(host_floor - need, PAGE)
        else:
            raise SystemExit("hbm_map: unknown arena policy %r" % policy)
    return [Region("<A descriptor arena>", base, need, "desc",
                   "gen_layer_program.py", stack_of(base))], base


# ------------------------------------------------------------------ the map

class HbmMap:
    def __init__(self, regions, hbm, notes=None, hbm_top=HBM_TOP):
        self.regions = list(regions)
        self.hbm = dict(hbm or {})
        self.notes = list(notes or [])
        self.hbm_top = hbm_top

    def by_kind(self, *kinds):
        return [r for r in self.regions if r.kind in kinds]

    def carve_kv(self):
        """The KV arena is DEFINED as everything from the end of the GDN state
        to the end of the device, so every top-anchored reservation overlaps it
        BY CONSTRUCTION.  That is a capacity CHARGE, not a collision, and
        reporting it as a fault would be noise that hides the real one.  Shrink
        the arena to the lowest top-anchored base and restate the context.

        An overlap between two TOP-ANCHORED regions is a different thing and
        stays a FAIL."""
        top = [r for r in self.regions if r.kind in ("host", "desc")]
        per = int(self.hbm.get("kv_bytes_per_token", 0)) or 1
        charged = 0
        for r in self.regions:
            if r.kind != "kv":
                continue
            # ONLY a reservation that sits INSIDE this extent is a charge.  An
            # earlier version took min() over every top-anchored base, so a
            # mutation that put the arena at address 0 shrank the KV arena to
            # zero bytes and the first reported fault was "nbytes 0 is not
            # positive" -- true, and not the fault anyone was looking for.  A
            # reservation BELOW the arena is a collision with whatever is down
            # there, and the overlap check says so on its own.
            inside = [t.base for t in top if r.base <= t.base < r.end]
            if not inside:
                continue
            floor_ = min(inside)
            cut = r.end - floor_
            charged += cut
            r.nbytes = max(0, r.nbytes - cut)
            self.notes.append(
                f"{r.name} shortened to {h(floor_)} by the top-anchored "
                f"reservations: {cut:,} B = {cut // per} tokens")
        return charged, charged // per

    # -------------------------------------------------------------- checks
    def check(self):
        """Every finding is a FAIL.  Returns a list of strings; empty is PASS.

        Teeth, in the order they were shown to bite (see the write-up):
          * an unaligned base;
          * a region outside the map, or with a non-positive length;
          * a region that CONTAINS the 4 GiB stack line strictly inside it --
            an out-of-stack read does not fault, it returns the wrong bytes and
            reports success;
          * a declared `stack` that is not the stack the base is really in;
          * ANY pairwise overlap, across ALL allocators.  This is the one that
            was missing: the two producers each checked their own regions."""
        fails = []
        for r in self.regions:
            if r.base % PAGE:
                fails.append(f"{r.name}: base {h(r.base)} is not 4 KB aligned "
                             f"(placed by {r.owner})")
            if r.base < 0 or r.end > self.hbm_top:
                fails.append(f"{r.name}: {h(r.base)}..{h(r.end)} is outside "
                             f"the {gib(self.hbm_top)} map (placed by {r.owner})")
            if r.nbytes <= 0:
                fails.append(f"{r.name}: nbytes {r.nbytes} is not positive")
            if r.base < STACK_LINE < r.end:
                fails.append(
                    f"{r.name}: {h(r.base)}..{h(r.end)} CONTAINS the stack "
                    f"line {h(STACK_LINE)}; an out-of-stack read does not "
                    f"fault, it returns the wrong bytes and reports success")
            if r.stack_field is not None and stack_of(r.base) != r.stack_field:
                fails.append(f"{r.name}: manifest says stack {r.stack_field}, "
                             f"base {h(r.base)} is in stack {stack_of(r.base)}")

        order = sorted(self.regions, key=lambda r: (r.base, r.end))
        for a, b in zip(order, order[1:]):
            if b.base < a.end:
                fails.append(
                    f"OVERLAP: {a.name} {h(a.base)}..{h(a.end)} "
                    f"(placed by {a.owner}) and {b.name} "
                    f"{h(b.base)}..{h(b.end)} (placed by {b.owner}) share "
                    f"{min(a.end, b.end) - b.base} bytes")
        return fails

    # -------------------------------------------------------------- report
    def rows(self):
        placed = [r for r in self.regions if r.kind in ("mv4i", "f32blob")]
        out = []
        if placed:
            order_p = sorted(placed, key=lambda r: r.base)
            holes = sum(b.base - a.end for a, b in zip(order_p, order_p[1:]))
            out.append(("packed weights + F32 blob", order_p[0].base,
                        sum(r.nbytes for r in placed), "pack_model_fk33.py",
                        f"{len(placed)} objects, {holes} B of stack-line hole"))
        for r in self.regions:
            if r.kind in ("mv4i", "f32blob"):
                continue
            note = ""
            if r.kind == "kv":
                per = int(self.hbm.get("kv_bytes_per_token", 1)) or 1
                note = f"{r.nbytes // per} tokens at {per} B/token, after the charge"
            elif r.kind in ("host", "desc"):
                note = "NOT reserved by the manifest"
            out.append((r.name.strip("<>"), r.base, r.nbytes, r.owner, note))
        out.sort(key=lambda t: t[1])
        return out

    def print_report(self, markdown=False):
        rows = self.rows()
        if markdown:
            print("| region | base | end | bytes | GiB | placed by | note |")
            print("|---|---|---|---|---|---|---|")
            for n, b, nb, own, note in rows:
                print(f"| {n} | `{h(b)}` | `{h(b + nb)}` | {nb:,} | "
                      f"{nb / 2**30:.4f} | `{own}` | {note} |")
        else:
            print(f"{'region':28s} {'base':>14s} {'end':>14s} {'bytes':>15s}  "
                  f"{'GiB':>8s}  {'placed by':22s} note")
            for n, b, nb, own, note in rows:
                print(f"{n:28s} {h(b):>14s} {h(b + nb):>14s} {nb:>15,}  "
                      f"{nb / 2**30:8.4f}  {own:22s} {note}")
        print()
        acc = sum(nb for _, _, nb, _, _ in rows)
        placed = [r for r in self.regions if r.kind in ("mv4i", "f32blob")]
        if placed:
            order_p = sorted(placed, key=lambda r: r.base)
            acc += sum(b.base - a.end for a, b in zip(order_p, order_p[1:]))
        print(f"device      {self.hbm_top:,} B = {gib(self.hbm_top)}")
        print(f"accounted   {acc:,} B = {gib(acc)}")
        print(f"unaccounted {self.hbm_top - acc:,} B")
        for n in self.notes:
            print(f"note: {n}")

    def to_json(self):
        return dict(
            hbm_top=self.hbm_top, stack_line=STACK_LINE,
            block_align=BLOCK_ALIGN, seam_hdr_bytes=SEAM_HDR_BYTES,
            desc_stride=DESC_STRIDE,
            regions=[dict(name=r.name, base=r.base, end=r.end,
                          nbytes=r.nbytes, kind=r.kind, owner=r.owner)
                     for r in sorted(self.regions, key=lambda r: r.base)],
            notes=self.notes)


# ------------------------------------------------------------------- plan()

def plan(mani, desc_jobs=311, desc_base=None, policy="below-host",
         max_chunk=512, want_host_blocks=True, n_embd=None, n_vocab=None,
         strict_arena=False):
    """THE ONE ENTRY POINT.  Build the whole map from a manifest.

    `mani` is a parsed manifest dict or a path to one.  Returns an `HbmMap`.
    Nothing here opens a payload file or a device.

    ORDER MATTERS AND IS NOT ARBITRARY.  The host blocks are placed FIRST,
    because `--policy below-host` puts the descriptor arena underneath them,
    and because that is the order the shipping code already has: the host's
    blocks come from the card's own CAPS at open time, and the arena is built
    offline by a tool that can be told where to go.  Reversing it is a real
    option and it is part of the decision that is Oren's."""
    if isinstance(mani, str):
        with open(mani) as f:
            mani = json.load(f)
    hbm = mani.get("hbm", {})
    top = int(hbm.get("size", HBM_TOP))
    notes = []
    regions = manifest_regions(mani)

    host_floor = None
    if want_host_blocks:
        if n_embd is None or n_vocab is None:
            lm = next((e for e in mani["files"]
                       if e.get("tensor") == "output.weight"), None)
            if lm is None:
                notes.append("no output.weight in the manifest, so n_embd and "
                             "n_vocab could not be inferred; the host blocks "
                             "are NOT modelled and no overlap with them can "
                             "be checked")
                want_host_blocks = False
            else:
                n_embd = n_embd if n_embd is not None else int(lm["K"])
                n_vocab = n_vocab if n_vocab is not None else int(lm["M"])
    if want_host_blocks:
        hb, raw = host_blocks(n_embd, n_vocab, max_chunk, top)
        regions += hb
        host_floor = raw["x_base"]
        notes.append(
            f"host blocks mirrored from pl_derive_bases() at n_embd={n_embd} "
            f"n_vocab={n_vocab} max_chunk={max_chunk}: {top - raw['x_base']:,} B "
            f"from {h(raw['x_base'])} to the top.  max_chunk is a RUNTIME cap "
            f"from CAPS, not a manifest field: a larger one moves x_base DOWN "
            f"and the arena with it.")

    da, base = desc_arena(desc_jobs, desc_base, policy, host_floor,
                          strict=strict_arena)
    regions += da
    if desc_jobs and not da:
        notes.append(
            "NO DESCRIPTOR ARENA IS IN THIS MAP.  The host blocks could not be "
            "modelled, so 'below-host' has no floor to sit under.  Nothing "
            "here has checked where gen_layer_program.py's descriptors go.")
    if da:
        if desc_base is not None:
            notes.append(f"descriptor arena base given explicitly: {h(base)}")
        elif policy == "top-down":
            notes.append(
                f"descriptor arena at gen_layer_program.py's HISTORIC top-down "
                f"default {h(base)}.  This is the placement that collides.")
        else:
            notes.append(
                f"descriptor arena placed by policy 'below-host' at {h(base)}: "
                f"the first 4 KB block below the host's R_X staging.  "
                f"INTERIM -- which allocator owns the top of HBM is Oren's "
                f"decision, not this tool's.")

    m = HbmMap(regions, hbm, notes, top)
    m.carve_kv()
    return m


# --------------------------------------------- the C, compiled and executed

C_PROBE = r"""
/* Generated by tools/hbm_map.py --check-c.  Not committed, not a fixture: it
 * is written to a temp dir, compiled against the REAL server/pl_backend.c, run,
 * and deleted.  Its two jobs:
 *
 *   1. print what pl_derive_bases() actually computes, so the Python mirror in
 *      hbm_map.host_blocks() can be required to equal it rather than merely
 *      resemble it;
 *   2. drive pl_check_bases() over a table of descriptor-arena placements, so
 *      the C refusal can be SHOWN to fire.  A checker never seen to fail has
 *      not been shown to work.
 */
#include <stdio.h>
#include <stdlib.h>
#include "pl_backend.h"
#include "fk33_seam.h"

static void emit_case(const char *name, pl_hbm_bases b,
                      unsigned long long abase, unsigned long long aspan)
{
    b.arena_base = abase;
    b.arena_span = aspan;
    printf("  {\"case\": \"%s\", \"arena_base\": %llu, \"arena_span\": %llu,"
           " \"rc\": %d},\n", name, abase, aspan, pl_check_bases(&b));
}

int main(int argc, char **argv)
{
    pl_hbm_bases b, p;
    int e;
    unsigned long long top;
    if (argc < 5) return 2;
    top = strtoull(argv[4], 0, 0);
    e = pl_derive_bases(atoi(argv[1]), atoi(argv[2]), atoi(argv[3]), top,
                        0, 0, &b);
    printf("{\"rc\": %d, \"x_base\": %llu, \"x_span\": %llu,"
           " \"l_base\": %llu, \"l_span\": %llu,"
           " \"desc_ptr\": %llu, \"desc_span\": %llu, \"hbm_top\": %llu,\n",
           e, (unsigned long long)b.x_base,   (unsigned long long)b.x_span,
              (unsigned long long)b.l_base,   (unsigned long long)b.l_span,
              (unsigned long long)b.desc_ptr, (unsigned long long)b.desc_span,
              (unsigned long long)b.hbm_top);
    printf(" \"arena_cases\": [\n");
    /* no arena declared: must still pass, and pl_open warns about the silence */
    emit_case("none", b, 0, 0);
    /* the HISTORIC gen_layer_program.py placement, 311 jobs at 512 B */
    emit_case("historic_top_down", b,
              (top - 311ull * 512ull) & ~0xFFFull, 159744ull);
    /* exactly one page over the D program */
    emit_case("on_d_program", b, (unsigned long long)b.desc_ptr, 4096ull);
    /* one page over the top of the logits row */
    emit_case("on_logits_tail", b,
              (unsigned long long)(b.l_base + b.l_span - 4096ull) & ~0xFFFull,
              4096ull);
    /* one page over the R_X staging block */
    emit_case("on_r_x", b, (unsigned long long)b.x_base, 4096ull);
    /* 512-B aligned but not 4 KB, and clear of every other block.  MUST PASS:
     * pl_check_bases demands 512-B alignment of the arena, not 4 KB.  The
     * first attempt at this case put the base 512 B HIGHER and so ran 512 B
     * into R_X; it was refused for OVERLAP and read as an alignment failure.
     * Kept as a case rather than deleted -- it is the resolution floor of the
     * alignment rule, and a case that cannot separate two reasons for a
     * refusal is not measuring the one it names. */
    emit_case("aligned_512_not_4k", b,
              (unsigned long long)b.x_base - 159744ull - 4096ull + 512ull,
              159744ull);
    /* misaligned below 512 */
    emit_case("misaligned_64", b,
              (unsigned long long)b.x_base - 159744ull - 4096ull + 64ull,
              159744ull);
    /* off the top of the device */
    emit_case("past_top", b, top - 4096ull, 8192ull);
    /* straddling the 4 GiB stack line */
    emit_case("straddles_stack_line", b,
              (unsigned long long)FK33_HBM_STACK_LINE - 4096ull, 8192ull);
    /* the below-host placement: the one that must be accepted */
    p = b;
    e = pl_place_desc_arena(&p, 159232ull);
    printf("  {\"case\": \"place_below_host\", \"arena_base\": %llu,"
           " \"arena_span\": %llu, \"rc\": %d}\n",
           (unsigned long long)p.arena_base, (unsigned long long)p.arena_span, e);
    printf(" ]}\n");
    return 0;
}
"""

C_SOURCES = ["pl_backend.c", "fk33_transport.c", "fk33_sim.c",
             "fk33_manifest.c"]


def check_against_c(n_embd, n_vocab, max_chunk, hbm_top=HBM_TOP, cc=None,
                    verbose=False):
    """Compile `server/pl_backend.c` and require the real C to agree.

    THIS IS THE ONLY EVIDENCE IN THIS FILE.  Everything above is a Python
    model; `host_blocks()` claims to reproduce `pl_derive_bases()` and that
    claim is worth nothing on its own.  Two Python copies agreeing would be
    the failure mode TRACK SCHED-FIX recorded, where a wrong constant survived
    because the two generators agreed with each other.

    Returns (ok, list_of_messages).  A compiler that is not present is
    reported as SKIP, not as a pass."""
    cc = cc or os.environ.get("CC", "cc")
    srcdir = os.path.join(REPO, "server")
    msgs = []
    with tempfile.TemporaryDirectory(prefix="hbm_map_c_") as td:
        cpath = os.path.join(td, "probe.c")
        with open(cpath, "w") as f:
            f.write(C_PROBE)
        exe = os.path.join(td, "probe")
        cmd = [cc, "-O1", "-std=c99", "-I", srcdir, "-o", exe, cpath] + \
              [os.path.join(srcdir, s) for s in C_SOURCES]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True)
        except OSError as e:
            return None, [f"SKIP  no C compiler ({cc}): {e}"]
        if p.returncode:
            return False, ["FAIL  the C probe did not compile:\n" + p.stderr]
        r = subprocess.run([exe, str(n_embd), str(n_vocab), str(max_chunk),
                            str(hbm_top)], capture_output=True, text=True)
        if r.returncode:
            return False, [f"FAIL  the C probe exited {r.returncode}: {r.stderr}"]
        got = json.loads(r.stdout)
    _, want = host_blocks(n_embd, n_vocab, max_chunk, hbm_top)
    ok = True
    for k in ("x_base", "x_span", "l_base", "l_span", "desc_ptr", "desc_span",
              "hbm_top"):
        if int(got[k]) != int(want[k]):
            ok = False
            msgs.append(f"FAIL  {k}: this file says {h(want[k])}, "
                        f"server/pl_backend.c says {h(int(got[k]))}")
        elif verbose:
            msgs.append(f"ok    {k} = {h(want[k])}  (C and Python agree)")
    if got["rc"] != 0:
        msgs.append(f"note  pl_derive_bases returned {got['rc']} "
                    f"(reserved_end was passed as 0 here, so only the "
                    f"self-consistency half of pl_check_bases ran)")
    if ok and not msgs:
        msgs.append("ok    all seven derived values match server/pl_backend.c")

    # ---- the arena teeth, run in the C.
    #
    # WANT is the verdict each placement MUST get, written down before the
    # numbers were seen.  A case that does not bite is reported under its own
    # name and kept: it is the resolution floor of the check, and this project
    # has repeatedly found that the non-biting rows are the informative ones.
    want_rc = {
        "none":                 0,   # not declared -> pl_open warns instead
        "historic_top_down":    "nonzero",
        "on_d_program":         "nonzero",
        "on_logits_tail":       "nonzero",
        "on_r_x":               "nonzero",
        "aligned_512_not_4k":   0,   # pl_check_bases demands 512, not 4096
        "misaligned_64":        "nonzero",
        "past_top":             "nonzero",
        "straddles_stack_line": "nonzero",
        "place_below_host":     0,
    }
    for cs in got.get("arena_cases", []):
        want = want_rc.get(cs["case"])
        rc = int(cs["rc"])
        got_kind = "nonzero" if rc else 0
        verdict = "ok  " if got_kind == want else "FAIL"
        if got_kind != want:
            ok = False
        msgs.append(f"{verdict}  pl_check_bases arena case {cs['case']:22s} "
                    f"base={h(int(cs['arena_base']))} span={cs['arena_span']} "
                    f"-> rc {rc} (wanted {want})")
    return ok, msgs


# ------------------------------------------------------------------- teeth
#
# A CHECKER NEVER SHOWN TO FAIL HAS NOT BEEN SHOWN TO WORK.  Each row mutates a
# real manifest or a real placement and states, BEFORE the run, whether
# `HbmMap.check()` must go red.  Rows that must go GREEN are not filler: the
# map deliberately treats a top-anchored region overlapping the KV arena as a
# capacity charge rather than a collision, and a row that pins that decision
# down is the only thing separating "by design" from "cannot see it".

def _teeth_cases(mani, max_chunk=512, desc_jobs=311):
    """Yield (name, want_red, builder) where builder returns an HbmMap."""

    def base_map(**kw):
        kw.setdefault("desc_jobs", desc_jobs)
        kw.setdefault("max_chunk", max_chunk)
        return plan(json.loads(json.dumps(mani)), **kw)

    def mutate(fn, **kw):
        m2 = json.loads(json.dumps(mani))
        fn(m2)
        kw.setdefault("desc_jobs", desc_jobs)
        kw.setdefault("max_chunk", max_chunk)
        return plan(m2, **kw)

    yield ("control_clean", False, lambda: base_map())

    yield ("arena_historic_top_down", True,
           lambda: base_map(policy="top-down"))

    yield ("arena_on_weight_image", True,
           lambda: base_map(desc_base=0))

    yield ("arena_straddles_stack_line", True,
           lambda: base_map(desc_base=STACK_LINE - 4096))

    yield ("arena_unaligned", True,
           lambda: base_map(desc_base=align_down(HBM_TOP, PAGE) - 8 * PAGE + 512))

    yield ("arena_past_top", True,
           lambda: base_map(desc_base=HBM_TOP - 4096))

    # A parameter, not an address.  max_chunk comes from the card's CAPS at
    # open time and nothing in the manifest constrains it; a bigger one drags
    # x_base down THROUGH a fixed arena.  This is the case that shows the map
    # has to be recomputed per shape and per cap, not stored as constants.
    yield ("max_chunk_grown_over_a_fixed_arena", True,
           lambda: base_map(desc_base=align_down(
               HBM_TOP - 5_226_496 - align_up(DESC_STRIDE * desc_jobs, PAGE),
               PAGE), max_chunk=4096))

    def _overlap_two_tensors(m2):
        f = [e for e in m2["files"] if e["kind"] == "mv4i"]
        f[7]["hbm_offset"] = f[6]["hbm_offset"]
    yield ("two_packed_tensors_on_one_address", True,
           lambda: mutate(_overlap_two_tensors))

    def _gdn_into_kv(m2):
        m2["hbm"]["gdn_state_base"] = int(m2["hbm"]["kv_base"]) + 4096
    yield ("gdn_state_moved_into_the_kv_arena", True,
           lambda: mutate(_gdn_into_kv))

    def _wrong_stack_field(m2):
        for e in m2["files"]:
            if int(e["hbm_offset"]) >= STACK_LINE:
                e["stack"] = 0
                return
    yield ("a_tensor_declares_the_wrong_stack", True,
           lambda: mutate(_wrong_stack_field))

    def _straddle_tensor(m2):
        big = max((e for e in m2["files"] if e["kind"] == "mv4i"),
                  key=lambda e: int(e["nbytes"]))
        big["hbm_offset"] = STACK_LINE - int(big["nbytes"]) // 2
    yield ("a_tensor_straddles_the_stack_line", True,
           lambda: mutate(_straddle_tensor))

    # MUST STAY GREEN.  The KV arena is defined as everything above the GDN
    # state, so every top-anchored reservation overlaps it by construction and
    # the map charges it instead of failing.  Naming the row is what stops that
    # design decision from being mistaken for blindness later.
    yield ("arena_inside_the_kv_arena_only", False,
           lambda: base_map(desc_base=align_down(
               int(mani["hbm"]["kv_base"]) + (1 << 30), PAGE)))

    # MUST STAY GREEN, and this is the resolution floor worth knowing: the map
    # sees ADDRESSES.  A descriptor arena of the right size in the right place
    # that is nonetheless filled with the wrong descriptors is invisible here,
    # and always will be.  That is gen_layer_program.py's and
    # fk33_load_weights.py verify's job, not this one.
    yield ("arena_right_place_wrong_jobcount", False,
           lambda: base_map(desc_jobs=1))


def run_teeth(mani, max_chunk=512, desc_jobs=311, verbose=True):
    rows, bad = [], 0
    for name, want_red, build_ in _teeth_cases(mani, max_chunk, desc_jobs):
        try:
            m = build_()
            fails = m.check()
        except SystemExit as e:
            fails = [f"SystemExit: {e}"]
        red = bool(fails)
        ok = (red == want_red)
        if not ok:
            bad += 1
        rows.append((name, want_red, red, len(fails), ok,
                     fails[0] if fails else ""))
    if verbose:
        print(f"{'mutation':40s} {'want':>5s} {'got':>5s} {'n':>3s}  verdict")
        for name, want_red, red, n, ok, first in rows:
            print(f"{name:40s} {'RED' if want_red else 'green':>5s} "
                  f"{'RED' if red else 'green':>5s} {n:>3d}  "
                  f"{'ok' if ok else 'DID NOT BITE'}")
            if first:
                print(f"    {first[:150]}")
    return bad, rows


# ----------------------------------------------- manifest keys, for option (a)

def manifest_hbm_patch(m):
    """The two keys a manifest would carry if Oren picks the manifest-region
    mechanism.  Printed, never written: `tools/pack_model_fk33.py` is not this
    track's file, and a tool that silently edits a manifest is a fourth
    allocator."""
    a = [r for r in m.regions if r.kind == "desc"]
    if not a:
        return None
    return {"desc_arena_base": a[0].base, "desc_arena_bytes": a[0].nbytes}


# ------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest")
    ap.add_argument("--desc-jobs", type=int, default=311,
                    help="A descriptors to reserve for (311 at the 9B token "
                         "program, MEASURED). 0 removes the arena entirely, "
                         "which is the 'descriptors live in host memory' "
                         "arrangement")
    ap.add_argument("--desc-base", type=lambda x: int(x, 0), default=None,
                    help="place the arena here instead of by policy")
    ap.add_argument("--policy", choices=("below-host", "top-down"),
                    default="below-host",
                    help="below-host: the first 4 KB block under the host's "
                         "R_X staging (INTERIM, see the docstring).  "
                         "top-down: gen_layer_program.py's historic default, "
                         "which COLLIDES")
    ap.add_argument("--max-chunk", type=int, default=512,
                    help="pl_open()'s max_chunk, which sets the R_X span")
    ap.add_argument("--no-host-blocks", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--check-c", action="store_true",
                    help="compile server/pl_backend.c and require the real "
                         "pl_derive_bases() to agree address for address")
    ap.add_argument("--self-test", action="store_true",
                    help="mutate a real manifest and require check() to go "
                         "red where it must and stay green where it must.  "
                         "Rows that DO NOT bite are printed under their own "
                         "names, because they are the resolution floor")
    ap.add_argument("--emit-manifest-hbm", action="store_true",
                    help="print the hbm.desc_arena_* keys a manifest would "
                         "carry under the manifest-region mechanism")
    a = ap.parse_args(argv)

    with open(a.manifest) as f:
        mani = json.load(f)

    if a.self_test:
        bad, _ = run_teeth(mani, a.max_chunk, a.desc_jobs)
        print()
        if bad:
            print(f"{bad} mutation(s) did not behave as predicted")
            return 1
        print("TEETH PASS  every mutation gave the verdict written down for it "
              "before it ran")
        return 0

    m = plan(mani, desc_jobs=a.desc_jobs, desc_base=a.desc_base,
             policy=a.policy, max_chunk=a.max_chunk,
             want_host_blocks=not a.no_host_blocks)
    fails = m.check()

    if a.json:
        j = m.to_json()
        j["fails"] = fails
        print(json.dumps(j, indent=1))
    else:
        m.print_report(a.markdown)

    rc = 0
    if a.check_c:
        lm = next((e for e in mani["files"]
                   if e.get("tensor") == "output.weight"), None)
        print()
        if lm is None:
            print("SKIP  no output.weight; cannot pick a shape for the C check")
        else:
            ok, msgs = check_against_c(int(lm["K"]), int(lm["M"]), a.max_chunk,
                                       int(mani.get("hbm", {}).get("size",
                                                                   HBM_TOP)),
                                       verbose=True)
            for s in msgs:
                print(s)
            if ok is False:
                rc = 1

    if a.emit_manifest_hbm:
        p = manifest_hbm_patch(m)
        print()
        print("# add to manifest.json's top-level \"hbm\" object:")
        print(json.dumps(p, indent=1) if p else "# no descriptor arena in this map")

    print()
    if fails:
        for s in fails:
            print(f"FAIL  {s}")
        print(f"\n{len(fails)} FAIL")
        return 1
    print("PASS  every region is aligned, in range, in one stack, and disjoint "
          f"across all {len({r.owner for r in m.regions})} allocators")
    return rc


if __name__ == "__main__":
    sys.exit(main())
