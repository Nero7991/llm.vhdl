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
GDN_STATE_BYTES = 48 * 6144 * 128 * 2      # SS audit: 72 MB, persistent
KV_BYTES_PER_TOKEN = 16 * 4 * 256 * 2 * 2  # 16 attention layers, K+V, int16


def align_up(n: int) -> int:
    return (n + ALIGN - 1) & ~(ALIGN - 1)


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
    tensors = list(rd.tensors)

    mv, nonmv = [], []
    for t in tensors:
        ne = [int(v) for v in t.shape]
        (mv if P.is_matvec(t.name, ne) else nonmv).append(t)
    print(f"tensors  {len(tensors)} total, {len(mv)} matvec, "
          f"{len(nonmv)} kept F32")
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
        size = P.packed_layout(M, K, rows_if, axi_dw)[-1]
        out = os.path.join(a.outdir, name + ".mv4i")

        if (not a.force) and os.path.exists(out) and os.path.getsize(out) == size:
            w_exp, out_shift = struct.unpack_from(
                "<ii", open(out, "rb").read(0x18), 0x10)
            recs.append(dict(name=name, M=M, K=K, w_exp=w_exp,
                             out_shift=out_shift, nbytes=size))
            logf.write(f"{name}\t{M}\t{K}\t{w_exp}\t{out_shift}\t"
                       f"{(K + P.BLOCK - 1)//P.BLOCK}\t{size}\t"
                       f"{size*8.0/(M*K):.4f}\t0.0\tKEPT\n")
            logf.flush()
            print(f"[{i+1}/{len(mv)}] {name} kept ({size} B)")
            sys.stdout.flush()
            continue

        t0 = time.perf_counter()
        W = P.tensor_as_mk(t)
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
                         out_shift=out_shift, nbytes=size))
        logf.write(f"{name}\t{M}\t{K}\t{w_exp}\t{out_shift}\t"
                   f"{(K + P.BLOCK - 1)//P.BLOCK}\t{size}\t"
                   f"{size*8.0/(M*K):.4f}\t{dt:.1f}\tPACKED\n")
        logf.flush()
        print(f"[{i+1}/{len(mv)}] {name} M={M} K={K} w_exp={w_exp} "
              f"out_shift={out_shift} {size} B "
              f"{size*8.0/(M*K):.3f} bpw {dt:.1f} s")
        sys.stdout.flush()

    logf.close()
    if a.only:
        print("--only given: no manifest written")
        return 0

    # ---------------------------------------------------------- the load map
    off = 0
    files = []
    print("hashing the set for the manifest ...")
    sys.stdout.flush()
    for r in recs:
        assert off % ALIGN == 0
        files.append(dict(file=r["name"] + ".mv4i", kind="mv4i",
                          tensor=r["name"], M=r["M"], K=r["K"],
                          w_exp=r["w_exp"], out_shift=r["out_shift"],
                          nbytes=r["nbytes"], hbm_offset=off,
                          blake2b_128=digest(
                              os.path.join(a.outdir, r["name"] + ".mv4i"))))
        assert r["nbytes"] % ALIGN == 0, r["name"]
        off += r["nbytes"]
    nm_base = align_up(off)
    files.append(dict(file="nonmatvec_f32.bin", kind="f32blob",
                      tensor=None, nbytes=nm_size, hbm_offset=nm_base,
                      blake2b_128=digest(nm_path),
                      entries=[dict(e, hbm_offset=nm_base + e["offset"])
                               for e in nm_entries]))
    weights_end = align_up(nm_base + nm_size)
    for f in files:
        assert f["hbm_offset"] % ALIGN == 0, f["file"]
        if f["kind"] == "f32blob":
            for e in f["entries"]:
                assert e["hbm_offset"] % ALIGN == 0, e["name"]

    total = sum(f["nbytes"] for f in files)
    gdn_base = weights_end
    kv_base = align_up(gdn_base + GDN_STATE_BYTES)
    free = HBM_SIZE - kv_base
    man = dict(
        format="llama.vhdl FK33 load manifest v1",
        source_gguf=os.path.abspath(a.gguf),
        generated=time.strftime("%Y-%m-%dT%H:%M:%S"),
        geometry=dict(rows_if=rows_if, axi_dw=axi_dw, block=P.BLOCK,
                      nports_w=nports, n_scale_sub=nss,
                      axi_read_masters=nports + nss),
        hbm=dict(size=HBM_SIZE, align=ALIGN,
                 weights_bytes=total, weights_end=weights_end,
                 gdn_state_base=gdn_base, gdn_state_bytes=GDN_STATE_BYTES,
                 kv_base=kv_base, kv_bytes_per_token=KV_BYTES_PER_TOKEN,
                 free_after_gdn=free,
                 max_context_tokens=free // KV_BYTES_PER_TOKEN),
        counts=dict(tensors=len(tensors), matvec=len(mv), f32=len(nonmv)),
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
    print(f"  free for KV      {free/G:.3f} GiB from {kv_base:#x} "
          f"=> {free // KV_BYTES_PER_TOKEN} tokens of context")
    print(f"  total elapsed    {time.perf_counter() - t_all:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
