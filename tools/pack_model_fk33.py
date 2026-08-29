#!/usr/bin/env python3
"""Pack a whole GGUF model into the subsystem A INT4 format, plus a load map.

`tools/pack_int4.py` packs ONE tensor.  This drives it over an entire model at
one geometry, carries the tensors A does NOT pack, and emits the machine
readable manifest a loader needs to place everything in HBM.

    pack_model_fk33.py MODEL.gguf OUTDIR --rows-if 48 --axi-dw 256

WHAT IT DOES NOT DO: it does not re-derive anything.  The classification is
`pack_int4.is_matvec`, the size is `pack_int4.packed_layout`, the bytes are
`pack_int4.quantize` + `pack_int4.pack`.  `--audit` and a packed set are then
incapable of disagreeing, which is the whole reason the split and the layout
were lifted into named functions rather than copied here.

THE 4 KB RULE.  Spec 6.4: `weight_offset` and `scale_offset` must be 4 KB
aligned, because an AXI4 burst may not cross a 4 KB boundary.  A packed file is
already a whole number of 4 KB pages (4 KB header + `align4k` sub-regions), so
placing every file at a 4 KB aligned HBM address keeps every sub-region inside
it aligned as well.  This allocator therefore only has to round the F32 side
file, and it asserts the property rather than trusting it.

THE 177 NON-MATVEC TENSORS -- A DECISION, NOT THE SPEC.  Norms, biases, ssm_a
and the 4-tap ssm_conv1d are 1D or tiny and A does not pack them, but they
still have to reach the card.  The specs do not pin an HBM layout for them:
sequencer D SS6.4 keeps the norm weights in D's URAM constant memory precisely
to spend zero HBM ports on them, and D SS8.1's note that "the table and norm
weights move to HBM" is conditional and unspecified.  So the layout below is
chosen here:

  * ONE contiguous side file, `nonmatvec_f32.bin`, so the 177 arrive in a
    single DMA rather than 177 transfers averaging 3 KB each;
  * each tensor stored as little-endian float32 in GGUF element order
    (ne0 fastest), which is what both the F32 source tensors and the
    dequantized BF16 ones already are, so nothing is permuted;
  * each tensor 4 KB aligned WITHIN the file, so that with the file itself at a
    4 KB aligned base every individual tensor is independently 4 KB aligned and
    can be DMA'd or read on its own;
  * the padding is 0x00, matching spec 6.4's pad fill for the packed files.

The cost of that alignment is under 1 MB across all 177.  Revisit it only if
something is ever specified.

THE STACK RULE.  The FK33 carries TWO 4 GiB HBM stacks and the split is at a
hard address, 0x1_0000_0000.  An AXI master on a stack-0 SAXI port that issues
an address above that does NOT fault: the address decodes (the HBM IP exposes
all 32 pseudo-channel segments on every port when both global switches are on,
MEASURED in docs/2026-08-28_can-27-read-masters-be-served.md section 2.1), so
the read returns SOMETHING and the job reports success.  That is the
silent-wrong-answer class named in docs/2026-08-27_hbm-residency-map.md item 5.4
and it is the reason this allocator exists rather than a bare running offset.

The rule implemented here: NO placed object may CONTAIN the boundary strictly
inside it.  It applies to a whole .mv4i file, which is stronger than it needs to
be -- the sub-regions inside a file are what the 27 masters actually read -- but
a file that is wholly inside one stack has every one of its 27 sub-regions
wholly inside that stack for free, and the stronger rule is the one a reader can
check without parsing a header.  When the next object would straddle, the
allocator SKIPS to the boundary and records the hole; it never reorders, so the
manifest stays a function of the GGUF's tensor order alone.

THE qkv SEGMENT PAD.  The GDN block's `attn_qkv` is a FUSED matrix: its rows
are q | k | v, and the layer program issues one matvec JOB PER SEGMENT so each
gets its own BFP block exponent.  A job that does not start at row 0 is a row
WINDOW, and a window can only begin on a TILE boundary.  At the 9B shape the
segments are 2048 | 2048 | 4096 and ROWS_IF is 48, so `2048 mod 48 = 32` and
`4096 mod 48 = 16`: two of the three windows are not expressible, and MEASURED
by `tools/gen_layer_program.py`, 48 of a token's 297 subsystem A jobs are
refused for exactly that reason.

So each segment but the last is padded with ZERO ROWS up to a whole tile
(`pack_int4.segment_row_plan`), moving the starts to 0, 2064 and 4128.  M in
the header and in the manifest becomes the PADDED row count; the logical count
and the per-segment windows are recorded alongside it as `M_logical` and
`segments`, which is where a program generator reads the windows from rather
than re-deriving them.  Cost: 48 dead rows in 8,192, one extra tile per file,
110,592 B per tensor and 2,654,208 B over the 24.  `--no-qkv-pad` reproduces
the historic unpadded set; `manifest["geometry"]["qkv_segment_pad"]` says which
one a set is.

WHAT THIS RULE DOES NOT DO, stated so it is not mistaken for a solved problem:
it puts each tensor wholly in ONE stack, and subsystem A reads every tensor with
27 masters that CANNOT all be on one stack (a stack offers at most 15 engine
ports after the host takes one).  So under this flat layout at least 12 of the
27 masters read out of their own stack on every tensor.  Fixing THAT is the
27-lane arena layout of the residency map section 3, which needs a build-time
lane->port->stack table that no bitstream in this repo has.  This allocator
removes the straddle; it does not make the flat layout port-local.

`--drop TENSOR` -- LEAVING A TENSOR OUT OF THE IMAGE ON PURPOSE.  A tensor the
card never reads still costs HBM if it is placed, and HBM is the binding
resource at N=4 cards (docs/debugging/2026-08-29_token-embd-drop.md).  `--drop`
names a GGUF tensor that is NOT to be packed, NOT to be placed and NOT to appear
in the manifest's `files`.  It is repeatable, it defaults to EMPTY -- so the
default set is exactly the set this tool produced before the option existed --
and it REFUSES a name that is not in the GGUF, because a typo that silently
drops nothing is the failure mode an option like this invites.

What it is NOT: it is not a deletion of the data.  The manifest records every
dropped tensor by name, shape, and the byte count it WOULD have occupied, next
to `source_gguf`, so the set says out loud what it lacks and where to get it.
Whoever owns the tensor off-card reads it from that GGUF, or from a .mv4i packed
separately; `tools/embed_gather.py` is the row-gather recipe for the latter.

The intended use is `--drop token_embd.weight`: the host owns the embedding
gather and writes R_X into the card over the region-file write port -- the
`hw_we / hw_reg / hw_addr / hw_data` ports of `rtl/llama_top.vhd` (:583 at the
time of writing) and the `tok_fsm` of `rtl/seq_opdec.vhd` (:611) that publishes
that write into the lock plane -- so nothing on the card reads the embedding
table.  Cited by SYMBOL because those files are edited often and a line number
goes stale within the day; one already had.  Revisit the drop if an on-card
gather opcode is ever added, which is the trigger recorded in the note above.
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pack_int4 as P                                        # noqa: E402
from gguf.gguf_reader import GGUFReader                       # noqa: E402

ALIGN = 4096
HBM_SIZE = 8 * 1024 ** 3
STACK_BYTES = 4 * 1024 ** 3                # one HBM stack; the boundary is here
GDN_STATE_BYTES = 48 * 6144 * 128 * 2      # SS audit: 72 MB, persistent
KV_BYTES_PER_TOKEN = 16 * 4 * 256 * 2 * 2  # 16 attention layers, K+V, int16


def align_up(n: int) -> int:
    return (n + ALIGN - 1) & ~(ALIGN - 1)


def stack_of(off: int) -> int:
    return off // STACK_BYTES


def place(off: int, nbytes: int):
    """Next legal base for `nbytes` at or after `off`.  See THE STACK RULE.

    Returns (base, hole_bytes).  `base` is 4 KB aligned and `[base, base+nbytes)`
    contains no stack boundary strictly inside it.  `hole_bytes` is what was
    skipped, which the caller records rather than silently loses.

    Written as a loop over boundaries rather than as one `if` so that it is
    correct for an object larger than a stack (it cannot be placed at all, and
    the loop terminates on the range check instead of looping forever) and for
    any future HBM with more than two stacks.
    """
    base = align_up(off)
    hole = 0
    while True:
        if nbytes > STACK_BYTES:
            raise ValueError(f"object of {nbytes} B cannot fit in a "
                             f"{STACK_BYTES} B stack")
        b = (base // STACK_BYTES + 1) * STACK_BYTES     # next boundary above
        if base + nbytes <= b:
            return base, hole                            # wholly inside a stack
        hole += b - base
        base = b                                         # skip to the boundary


def digest(path: str) -> str:
    """blake2b-128 of a file, recorded in the manifest.

    WITHOUT this the manifest pins only sizes and headers, and a single flipped
    payload byte -- the exact damage a bad disk or a half-finished write leaves
    -- passes every structural check there is.  Measured: `check_mv4i_set.py`
    returned PASS on a file with byte 8192 set to 0xFF.  It is the same digest
    `fk33ctl.py load --verify` prints for the source, so the file on disk, the
    manifest and the bytes in HBM can all be compared to one number.
    """
    h = hashlib.blake2b(digest_size=16)
    with open(path, "rb") as f:
        while True:
            c = f.read(8 << 20)
            if not c:
                break
            h.update(c)
    return h.hexdigest()


def safe_name(name: str) -> str:
    """GGUF tensor names are already filesystem safe here; refuse if not."""
    if "/" in name or name in (".", "..") or name.startswith("-"):
        raise ValueError(f"tensor name is not a safe filename: {name!r}")
    return name


def dequant_f32(t) -> np.ndarray:
    """One GGUF tensor as a flat little-endian float32 array, GGUF order.

    `tensor_as_mk` reshapes to (M, K) without reordering, so flattening it
    again yields exactly the GGUF element order (ne0 fastest).  Going through
    it rather than calling `quants.dequantize` here keeps one dequantization
    path in the tree.
    """
    return np.ascontiguousarray(P.tensor_as_mk(t).reshape(-1), dtype="<f4")


def gguf_kv(rd, suffix: str):
    """One GGUF metadata value, addressed by key SUFFIX so the architecture
    prefix (`qwen35.`) does not have to be assumed.  Raises if it is missing or
    ambiguous: a fused-tensor split guessed from a default is exactly the kind
    of silent wrong number this repository keeps paying for."""
    hits = [k for k in rd.fields if k == suffix or k.endswith("." + suffix)]
    if len(hits) != 1:
        raise KeyError(f"GGUF metadata key {suffix!r}: {len(hits)} matches")
    return rd.fields[hits[0]].contents()


def qkv_segments(rd, M: int):
    """The q | k | v row segments of a fused GDN `attn_qkv`, DERIVED from the
    GGUF's own metadata and CHECKED against the tensor's row count.

        key_dim = ssm.state_size * ssm.group_count      (lin_head_dim * lin_key_heads)
        val_dim = ssm.inner_size
        M       = 2 * key_dim + val_dim

    `rtl/model_cfg_pkg.vhd:32-33` states the first two identities; the third is
    `gen_layer_program.Shape.qkv_dim`.  If the identity does not hold the split
    is unknown and nothing is padded -- the caller raises rather than assuming
    2048/2048/4096, which is a per-model number, not a constant.
    """
    key_dim = int(gguf_kv(rd, "ssm.state_size")) * int(gguf_kv(rd, "ssm.group_count"))
    val_dim = int(gguf_kv(rd, "ssm.inner_size"))
    if 2 * key_dim + val_dim != M:
        raise ValueError(
            f"attn_qkv has {M} rows but the GGUF metadata gives "
            f"2*{key_dim} + {val_dim} = {2 * key_dim + val_dim}; the fused "
            f"split is not what this model says it is")
    return [key_dim, key_dim, val_dim], ["q", "k", "v"]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gguf")
    ap.add_argument("outdir")
    ap.add_argument("--rows-if", type=int, default=48)
    ap.add_argument("--axi-dw", type=int, default=256)
    ap.add_argument("--only", default=None,
                    help="pack only tensors whose name contains this substring")
    ap.add_argument("--force", action="store_true",
                    help="repack even when an output of the right size exists")
    ap.add_argument("--no-qkv-pad", dest="qkv_pad", action="store_false",
                    default=True,
                    help="do NOT pad the fused attn_qkv row segments up to a "
                         "whole ROWS_IF tile. Reproduces the historic set, in "
                         "which two of the three qkv row windows per GDN block "
                         "are not expressible at ROWS_IF=48")
    ap.add_argument("--drop", action="append", default=[], metavar="TENSOR",
                    help="exact GGUF tensor name to leave OUT of the image: not "
                         "packed, not placed, not in the manifest's files. "
                         "Repeatable. DEFAULT: drop nothing, which reproduces "
                         "the set this tool made before the option existed. "
                         "Refuses a name the GGUF does not have. Intended use "
                         "is --drop token_embd.weight, because the host owns "
                         "the embedding gather and nothing on the card reads "
                         "that tensor")
    a = ap.parse_args()

    rows_if, axi_dw = a.rows_if, a.axi_dw
    nports = P.check_geometry(rows_if, axi_dw, emitting=True)
    nss = P.n_scale_sub(rows_if, axi_dw)
    os.makedirs(a.outdir, exist_ok=True)

    print(f"model    {a.gguf}")
    print(f"outdir   {a.outdir}")
    print(f"geometry ROWS_IF={rows_if} AXI_DW={axi_dw} BLOCK={P.BLOCK} "
          f"-> NPORTS_W={nports} n_scale_sub={nss} "
          f"({nports + nss} AXI read masters)")
    sys.stdout.flush()

    rd = GGUFReader(a.gguf, "r")
    all_tensors = list(rd.tensors)

    # ---------------------------------------------------------- --drop
    # Resolved against the GGUF's own tensor list and REFUSED if a name does
    # not match exactly one tensor.  An unmatched --drop would otherwise be a
    # no-op that still reports success, i.e. an image nobody notices is full
    # size.  Done before classification so a dropped tensor is invisible to
    # everything downstream: it is not packed, not placed, not counted.
    drop_names = list(dict.fromkeys(a.drop))          # dedup, keep order
    by_name = {}
    for t in all_tensors:
        by_name.setdefault(t.name, []).append(t)
    for n in drop_names:
        if len(by_name.get(n, [])) != 1:
            raise SystemExit(
                f"--drop {n!r}: the GGUF has {len(by_name.get(n, []))} tensors "
                f"with that exact name, want exactly 1. Nothing was written.")
    dropped = []
    for n in drop_names:
        t = by_name[n][0]
        ne = [int(v) for v in t.shape]
        is_mv = P.is_matvec(t.name, ne)
        would = (P.packed_layout(ne[1], ne[0], rows_if, axi_dw,
                                 emitting=False)[-1] if is_mv
                 else align_up(int(np.prod(ne)) * 4))
        dropped.append(dict(name=n, shape_ne=ne, matvec=bool(is_mv),
                            bytes_if_placed=int(would)))
    tensors = [t for t in all_tensors if t.name not in set(drop_names)]

    mv, nonmv = [], []
    for t in tensors:
        ne = [int(v) for v in t.shape]
        (mv if P.is_matvec(t.name, ne) else nonmv).append(t)
    print(f"tensors  {len(all_tensors)} in the GGUF, {len(dropped)} dropped, "
          f"{len(tensors)} placed: {len(mv)} matvec, {len(nonmv)} kept F32")
    for d in dropped:
        print(f"  DROPPED {d['name']} ne={d['shape_ne']} "
              f"{'matvec' if d['matvec'] else 'f32'}, "
              f"{d['bytes_if_placed']} B not placed")
    sys.stdout.flush()

    # ---------------------------------------------------- the 177, one blob
    nm_path = os.path.join(a.outdir, "nonmatvec_f32.bin")
    nm_entries, cur = [], 0
    for t in nonmv:
        ne = [int(v) for v in t.shape]
        nbytes = int(np.prod(ne)) * 4
        nm_entries.append(dict(name=t.name, shape_ne=ne, offset=cur,
                               nbytes=nbytes, dtype="f32le"))
        cur = align_up(cur + nbytes)
    nm_size = cur

    if a.only is None and (a.force or not os.path.exists(nm_path)
                           or os.path.getsize(nm_path) != nm_size):
        t0 = time.perf_counter()
        with open(nm_path, "wb") as f:
            f.truncate(nm_size)
            for t, e in zip(nonmv, nm_entries):
                blob = dequant_f32(t).tobytes()
                assert len(blob) == e["nbytes"], (t.name, len(blob), e["nbytes"])
                f.seek(e["offset"])
                f.write(blob)
        assert os.path.getsize(nm_path) == nm_size
        print(f"wrote nonmatvec_f32.bin  {nm_size} bytes, {len(nonmv)} tensors, "
              f"{time.perf_counter() - t0:.1f} s")
    elif a.only is not None:
        print(f"--only given: nonmatvec_f32.bin not touched "
              f"(it would be {nm_size} bytes)")
    else:
        print(f"nonmatvec_f32.bin present at {nm_size} bytes, kept")
    sys.stdout.flush()

    # ------------------------------------------------------- the 250 matvec
    log_path = os.path.join(a.outdir, "pack.log")
    logf = open(log_path, "a")
    logf.write(f"# {time.strftime('%Y-%m-%d %H:%M:%S')} ROWS_IF={rows_if} "
               f"AXI_DW={axi_dw} NPORTS_W={nports} n_scale_sub={nss}\n")
    logf.write("# name\tM\tK\tw_exp\tout_shift\tNB\tbytes\tbits_per_weight\t"
               "seconds\tstatus\n")
    logf.flush()

    recs = []
    t_all = time.perf_counter()
    for i, t in enumerate(mv):
        name = safe_name(t.name)
        if a.only and a.only not in name:
            continue
        ne = [int(v) for v in t.shape]
        K, M = ne[0], ne[1]

        # THE qkv SEGMENT PAD.  See the module docstring.  `M` from here on is
        # the PADDED row count -- it is what the header, the file size and the
        # manifest all have to agree on -- and `m_logical`/`segs` carry the
        # real rows and the windows a program generator issues.
        seg_plan, segs, m_logical = None, None, M
        if a.qkv_pad and name.endswith("attn_qkv.weight"):
            seg_rows, seg_names = qkv_segments(rd, M)
            M, seg_plan = P.segment_row_plan(seg_rows, rows_if)
            segs = [dict(name=nm, row_start=q["row_start"], n_rows=q["n_rows"],
                         pad_rows=q["pad"], logical_row=q["src_start"])
                    for nm, q in zip(seg_names, seg_plan)]
            for q in segs:
                assert q["row_start"] % rows_if == 0, (name, q)
            assert M >= m_logical

        size = P.packed_layout(M, K, rows_if, axi_dw)[-1]
        out = os.path.join(a.outdir, name + ".mv4i")

        if (not a.force) and os.path.exists(out) and os.path.getsize(out) == size:
            w_exp, out_shift = struct.unpack_from(
                "<ii", open(out, "rb").read(0x18), 0x10)
            recs.append(dict(name=name, M=M, K=K, w_exp=w_exp,
                             out_shift=out_shift, nbytes=size,
                             m_logical=m_logical, segments=segs))
            logf.write(f"{name}\t{M}\t{K}\t{w_exp}\t{out_shift}\t"
                       f"{(K + P.BLOCK - 1)//P.BLOCK}\t{size}\t"
                       f"{size*8.0/(m_logical*K):.4f}\t0.0\tKEPT\n")
            logf.flush()
            print(f"[{i+1}/{len(mv)}] {name} kept ({size} B)")
            sys.stdout.flush()
            continue

        t0 = time.perf_counter()
        W = P.tensor_as_mk(t)
        assert W.shape == (m_logical, K), (W.shape, m_logical, K)
        if seg_plan is not None:
            W = P.apply_segment_padding(W, M, seg_plan)
        assert W.shape == (M, K), (W.shape, M, K)
        idx, scale, w_exp = P.quantize(W, P.IQ4_NL)
        del W                                   # 4 GB on the two 1.0e9 tensors
        out_shift = P.calibrate_out_shift(K)
        blob = P.pack(idx, scale, w_exp, M, K, rows_if, out_shift,
                      P.IQ4_NL, axi_dw)
        del idx, scale
        assert len(blob) == size, (len(blob), size)
        tmp = out + ".part"
        with open(tmp, "wb") as f:
            f.write(blob)
        del blob
        os.replace(tmp, out)
        dt = time.perf_counter() - t0

        recs.append(dict(name=name, M=M, K=K, w_exp=w_exp,
                         out_shift=out_shift, nbytes=size,
                         m_logical=m_logical, segments=segs))
        logf.write(f"{name}\t{M}\t{K}\t{w_exp}\t{out_shift}\t"
                   f"{(K + P.BLOCK - 1)//P.BLOCK}\t{size}\t"
                   f"{size*8.0/(m_logical*K):.4f}\t{dt:.1f}\tPACKED\n")
        logf.flush()
        print(f"[{i+1}/{len(mv)}] {name} M={M} K={K} w_exp={w_exp} "
              f"out_shift={out_shift} {size} B "
              f"{size*8.0/(m_logical*K):.3f} bpw {dt:.1f} s")
        sys.stdout.flush()

    logf.close()
    if a.only:
        print("--only given: no manifest written")
        return 0

    # ---------------------------------------------------------- the load map
    off = 0
    files = []
    holes = []
    print("hashing the set for the manifest ...")
    sys.stdout.flush()
    for r in recs:
        assert off % ALIGN == 0
        base, hole = place(off, r["nbytes"])
        if hole:
            holes.append(dict(offset=off, nbytes=hole,
                              why=f"stack boundary before {r['name']}.mv4i"))
        ent = dict(file=r["name"] + ".mv4i", kind="mv4i",
                   tensor=r["name"], M=r["M"], K=r["K"],
                   w_exp=r["w_exp"], out_shift=r["out_shift"],
                   nbytes=r["nbytes"], hbm_offset=base,
                   stack=stack_of(base),
                   blake2b_128=digest(
                       os.path.join(a.outdir, r["name"] + ".mv4i")))
        if r.get("segments"):
            # M is the PADDED row count everywhere a size is derived from it.
            # These two fields are the only place the LOGICAL shape and the
            # per-segment row windows are written down, and they exist so that
            # a program generator reads them instead of re-deriving 2064/4128.
            ent["M_logical"] = r["m_logical"]
            ent["segments"] = r["segments"]
        files.append(ent)
        assert r["nbytes"] % ALIGN == 0, r["name"]
        off = base + r["nbytes"]
    nm_base, hole = place(off, nm_size)
    if hole:
        holes.append(dict(offset=off, nbytes=hole,
                          why="stack boundary before nonmatvec_f32.bin"))
    files.append(dict(file="nonmatvec_f32.bin", kind="f32blob",
                      tensor=None, nbytes=nm_size, hbm_offset=nm_base,
                      stack=stack_of(nm_base),
                      blake2b_128=digest(nm_path),
                      entries=[dict(e, hbm_offset=nm_base + e["offset"])
                               for e in nm_entries]))
    weights_end = align_up(nm_base + nm_size)
    for f in files:
        assert f["hbm_offset"] % ALIGN == 0, f["file"]
        # THE STACK RULE, asserted rather than trusted: the file itself, and
        # every sub-region a master will read out of it.  A .mv4i is a header
        # plus NPORTS_W + n_scale_sub sub-regions, so checking the file is
        # sufficient AND checking it again per sub-region costs nothing.
        assert stack_of(f["hbm_offset"]) \
            == stack_of(f["hbm_offset"] + f["nbytes"] - 1), \
            f'{f["file"]} straddles the {STACK_BYTES} B stack boundary'
        if f["kind"] == "mv4i":
            lay = P.packed_layout(f["M"], f["K"], rows_if, axi_dw,
                                  emitting=False)
            _, _, np_, sub_sz, nss_, scl_sz, tot_ = lay
            assert tot_ == f["nbytes"], (f["file"], tot_, f["nbytes"])
            subs = [(P.HDR_BYTES + sub_sz * p, sub_sz) for p in range(np_)]
            so = P.HDR_BYTES + sub_sz * np_
            subs += [(so + scl_sz * q, scl_sz) for q in range(nss_)]
            for o, n in subs:
                s = f["hbm_offset"] + o
                assert stack_of(s) == stack_of(s + n - 1), \
                    f'{f["file"]} sub-region at +{o} straddles the boundary'
        if f["kind"] == "f32blob":
            for e in f["entries"]:
                assert e["hbm_offset"] % ALIGN == 0, e["name"]
                assert stack_of(e["hbm_offset"]) \
                    == stack_of(e["hbm_offset"] + e["nbytes"] - 1), e["name"]

    total = sum(f["nbytes"] for f in files)
    gdn_base, hole = place(weights_end, GDN_STATE_BYTES)
    if hole:
        holes.append(dict(offset=weights_end, nbytes=hole,
                          why="stack boundary before the GDN state region"))
    kv_base = align_up(gdn_base + GDN_STATE_BYTES)
    free = HBM_SIZE - kv_base
    hole_bytes = sum(h["nbytes"] for h in holes)

    # KV is a REGION, not an object, so the stack rule applies to the per-token
    # RECORD, not to the region.  Split the region at every stack boundary and
    # count whole records inside each extent; that makes a straddling record
    # impossible by construction rather than by an alignment coincidence, and
    # the extent list is what a KV allocator needs anyway.  The old
    # `free // KV_BYTES_PER_TOKEN` silently permitted one straddling record per
    # boundary crossed.
    kv_extents, p = [], kv_base
    while p < HBM_SIZE:
        e = min((p // STACK_BYTES + 1) * STACK_BYTES, HBM_SIZE)
        kv_extents.append(dict(base=p, nbytes=e - p, stack=stack_of(p),
                               tokens=(e - p) // KV_BYTES_PER_TOKEN))
        p = e
    max_ctx = sum(x["tokens"] for x in kv_extents)

    man = dict(
        format="llama.vhdl FK33 load manifest v1",
        source_gguf=os.path.abspath(a.gguf),
        generated=time.strftime("%Y-%m-%dT%H:%M:%S"),
        geometry=dict(rows_if=rows_if, axi_dw=axi_dw, block=P.BLOCK,
                      nports_w=nports, n_scale_sub=nss,
                      axi_read_masters=nports + nss,
                      qkv_segment_pad=bool(a.qkv_pad)),
        hbm=dict(size=HBM_SIZE, align=ALIGN, stack_bytes=STACK_BYTES,
                 weights_bytes=total, weights_end=weights_end,
                 stack_holes=holes, stack_hole_bytes=hole_bytes,
                 gdn_state_base=gdn_base, gdn_state_bytes=GDN_STATE_BYTES,
                 gdn_state_stack=stack_of(gdn_base),
                 kv_base=kv_base, kv_bytes_per_token=KV_BYTES_PER_TOKEN,
                 kv_extents=kv_extents,
                 free_after_gdn=free,
                 max_context_tokens=max_ctx),
        # `tensors` counts what is PLACED, so it stays the sum of matvec+f32
        # and `check_mv4i_set.py`'s count check keeps its meaning.  What the
        # GGUF held is recorded separately, so the two can never be confused.
        counts=dict(tensors=len(tensors), matvec=len(mv), f32=len(nonmv),
                    gguf_tensors=len(all_tensors), dropped=len(dropped)),
        dropped_tensors=dropped,
        files=files,
    )
    mpath = os.path.join(a.outdir, "manifest.json")
    with open(mpath, "w") as f:
        json.dump(man, f, indent=1)
    print(f"\nwrote {mpath}")
    G = 1024.0 ** 3
    print(f"  weights          {total} B  {total/G:.3f} GiB  "
          f"({100.0*total/HBM_SIZE:.1f} % of 8 GiB)")
    print(f"  GDN state        {GDN_STATE_BYTES/1024**2:.1f} MB at "
          f"{gdn_base:#x}")
    if dropped:
        tot_d = sum(d["bytes_if_placed"] for d in dropped)
        print(f"  dropped          {len(dropped)} tensor(s), {tot_d} B "
              f"({tot_d/G:.3f} GiB) NOT placed: "
              + ", ".join(d["name"] for d in dropped))
    else:
        print("  dropped          none")
    print(f"  qkv segment pad  {'on' if a.qkv_pad else 'OFF'}, "
          f"{sum(1 for f in files if f.get('segments'))} fused tensor(s) padded")
    print(f"  stack holes      {hole_bytes} B  {hole_bytes/1024**2:.1f} MiB "
          f"in {len(holes)} hole(s)")
    for h in holes:
        print(f"    {h['nbytes']} B at {h['offset']:#x}: {h['why']}")
    print(f"  free for KV      {free/G:.3f} GiB from {kv_base:#x} "
          f"=> {max_ctx} tokens of context "
          f"in {len(kv_extents)} per-stack extent(s)")
    print(f"  total elapsed    {time.perf_counter() - t_all:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
