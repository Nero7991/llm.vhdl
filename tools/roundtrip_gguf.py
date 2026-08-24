#!/usr/bin/env python3
"""Round-trip a GGUF's weights through subsystem A's INT4 format and rewrite it.

WHY THIS EXISTS.  Every resource, timing and bandwidth number in this project
assumes subsystem A's weight format is good enough to run the model, and that
assumption has never been tested above the level of a single tensor.  It is not
a safe assumption, for a reason the model file itself makes obvious:

  Qwen3.8-27B-Q4_K_M is NOT a uniformly 4-bit model.  llama.cpp's mixed recipe
  stores ffn_gate/up/down and token_embd as Q4_K, output.weight as Q6_K, and
  attn_qkv / attn_gate / ssm_out / ssm_alpha / ssm_beta as **Q8_0** -- eight
  bits, because those projections are the ones that do not tolerate coarse
  quantization.

Subsystem A's format is a uniform ~4.5 bits (IQ4_NL codebook + per-32 uint15
scale + per-matrix exponent) for everything it streams.  Running it therefore
pushes the attention and SSM projections from 8 bits down to 4.5.  That may be
fine, or it may not be; this tool exists so the answer is measured rather than
assumed.

WHAT IT MEASURES, AND THE CONTROL THAT MAKES IT MEAN ANYTHING.  The output has
to be stored in SOME format, and the storage format contributes its own error.
So the experiment is a difference, not an absolute:

  --mode control    dequantize -> requantize to the output type.  No A format.
  --mode a          dequantize -> A quantize -> A dequantize -> output type.

A's true cost is ppl(a) - ppl(control), with the untouched source file's ppl as
context.  Quoting ppl(a) against the source alone would charge A for the storage
requantization as well, which is not A's to pay.

  --mode a --only-q4k   applies A ONLY to tensors already stored at Q4_K, so
                        the Q8_0 projections keep their precision.  This
                        attributes any damage: if control -> only-q4k is small
                        and only-q4k -> a is large, the loss is specifically
                        from degrading the 8-bit tensors, and the fix is a
                        mixed-precision path rather than a different codebook.

The A format itself is imported from pack_int4.py rather than reimplemented, so
this cannot drift from what the packer and the RTL actually do.
"""
import argparse
import os
import sys

import numpy as np

# Reversed so the FIRST path listed ends up first on sys.path.  It must be the
# dflash2 checkout, because that is the tree llama-cpp-server is built from and
# therefore the one whose quantize/dequantize the perplexity run will use; a
# silent mismatch between the writer's Q8_0 and the runtime's would show up as
# an unexplained perplexity delta and be blamed on subsystem A.
for _p in reversed(("/mnt/storage/llama-dflash2-src/gguf-py",
                    os.path.expanduser("~/GitHub/llama.cpp.upstream/gguf-py"))):
    if os.path.isdir(_p):
        sys.path.insert(0, _p)

from gguf import (GGUFReader, GGUFWriter, GGMLQuantizationType,  # noqa: E402
                  GGUFValueType, GGML_QUANT_SIZES)
from gguf import quants                                                       # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pack_int4 import quantize, IQ4_NL, BLOCK                                 # noqa: E402


def a_dequantize(idx, scl, w_exp, K, cb=IQ4_NL):
    """Inverse of pack_int4.quantize: (M,NB,32) idx + (M,NB) scale -> (M,K) f32.

    Mirrors spec 6.1 exactly:  w = codebook[idx] * (scale / 2^15) * 2^-w_exp.
    The 2^15 here is 32768.0, matching the packer's own forward direction --
    getting this constant wrong is silent, since it just rescales the whole
    matrix and perplexity would still be finite, merely wrong.
    """
    cbf = cb.astype(np.float32)
    vals = cbf[idx]                                    # (M, NB, 32)
    s = (scl.astype(np.float32) / np.float32(32768.0))[:, :, None]
    out = vals * s * np.float32(2.0) ** (-w_exp)
    M = idx.shape[0]
    return out.reshape(M, -1)[:, :K].astype(np.float32)


# Tensors subsystem A streams: 2-D weight matrices consumed as y = W.x.
# Deliberately EXCLUDED, with reasons, because a silent inclusion here would
# quietly change what the experiment is measuring:
#   token_embd  -- a gather, not a matvec; the FPGA indexes it, never multiplies
#   output      -- the LM head is a matvec, but see --include-output; left out by
#                  default so the headline number is about the transformer body
#   ssm_conv1d  -- a depthwise convolution, not a matrix multiply
#   *_norm, ssm_a, ssm_dt.bias -- 1-D parameters, F32, not streamed as weights
SKIP_SUBSTR = ("_norm.", "norm.weight", "ssm_conv1d", "ssm_a", "ssm_dt",
               "token_embd")


def is_a_tensor(name, shape, include_output):
    if len(shape) != 2 or min(shape) < BLOCK:
        return False
    if name == "output.weight":
        return include_output
    return not any(s in name for s in SKIP_SUBSTR)


def copy_metadata(rd, wr, skip=()):
    """Copy every KV field except the ones GGUFWriter emits itself."""
    n = 0
    for name, field in rd.fields.items():
        if name in skip or not field.types:
            continue
        vt = field.types[0]
        try:
            if vt == GGUFValueType.ARRAY:
                sub = field.types[1]
                vals = [field.contents(i) for i in range(len(field.data))]
                if sub == GGUFValueType.STRING:
                    vals = [v.decode("utf-8") if isinstance(v, bytes) else v
                            for v in vals]
                wr.add_key_value(name, vals, GGUFValueType.ARRAY, sub_type=sub)
            else:
                v = field.contents()
                if isinstance(v, bytes):
                    v = v.decode("utf-8")
                wr.add_key_value(name, v, vt)
            n += 1
        except Exception as e:                     # loud, never silent
            print(f"  WARNING: could not copy metadata field {name!r}: {e}")
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--mode", choices=("control", "a"), required=True)
    ap.add_argument("--only-q4k", action="store_true",
                    help="apply A only to tensors already stored at Q4_K")
    ap.add_argument("--include-output", action="store_true",
                    help="also round-trip output.weight (the LM head)")
    ap.add_argument("--out-type", default="Q8_0",
                    help="storage type for 2-D tensors (default Q8_0)")
    ap.add_argument("--limit", type=int, default=0,
                    help="stop after N A-tensors; for smoke-testing the writer")
    args = ap.parse_args()

    out_qt = getattr(GGMLQuantizationType, args.out_type)
    rd = GGUFReader(args.src, "r")

    arch_f = rd.fields.get("general.architecture")
    arch = arch_f.contents()
    if isinstance(arch, bytes):
        arch = arch.decode("utf-8")
    print(f"source {args.src}\n  arch={arch}  tensors={len(rd.tensors)}")

    wr = GGUFWriter(args.dst, arch)
    # GGUF.version / tensor_count / kv_count are HEADER fields that the reader
    # synthesizes as if they were KV entries.  They are not, and copying them
    # emits real duplicates that make the file unreadable
    # ("Duplicate GGUF.version already in list").  general.architecture is
    # skipped because GGUFWriter emits it from its constructor argument.
    ncopy = copy_metadata(rd, wr, skip=("general.architecture",
                                        "GGUF.version",
                                        "GGUF.tensor_count",
                                        "GGUF.kv_count"))
    print(f"  copied {ncopy} metadata fields")

    # TWO PASSES, and the reason is memory, not tidiness.
    #
    # GGUFWriter defaults to use_temp_file=False, which means add_tensor()
    # RETAINS every tensor in RAM until write_tensors_to_file().  For a 27B
    # model that is ~29 GiB of tensor data on a 31 GiB box: the first attempt at
    # this reached 20.5 GB RSS with 10 GB left and had to be killed before
    # systemd-oomd took the whole cgroup with it (this machine has done that
    # before -- see the OOM note in the workstation CLAUDE.md).
    #
    # So: pass 1 registers tensor INFO only, which needs nothing but shapes and
    # types and so reads no tensor data at all; then the header, KV and tensor
    # table are written; then pass 2 streams one tensor at a time through
    # write_tensor_data().  Peak memory is one tensor.
    #
    # The two passes MUST visit tensors in the same order -- write_tensor_data
    # pops tensor infos in insertion order and asserts the byte count matches,
    # so a reordering is caught rather than silently producing a corrupt file.
    blk_sz, ty_sz = GGML_QUANT_SIZES[out_qt]
    plan = []
    for t in rd.tensors:
        ne = [int(x) for x in t.shape]
        tname = str(t.tensor_type).split(".")[-1]
        passthru = len(ne) < 2 or tname == "F32"
        if passthru:
            wr.add_tensor_info(t.name, list(t.data.shape), t.data.dtype,
                               t.data.nbytes, raw_dtype=t.tensor_type)
        else:
            K, M = ne[0], ne[1]
            nbytes = (M * K // blk_sz) * ty_sz
            wr.add_tensor_info(t.name, [M, (K // blk_sz) * ty_sz], np.uint8,
                               nbytes, raw_dtype=out_qt)
        plan.append((t, passthru, tname))

    wr.write_header_to_file()
    wr.write_kv_data_to_file()
    wr.write_ti_data_to_file()

    n_a = n_pass = n_f32 = 0
    for t, passthru, tname in plan:
        if passthru:
            wr.write_tensor_data(t.data)
            n_f32 += 1
            continue

        ne = [int(x) for x in t.shape]
        K, M = ne[0], ne[1]
        W = quants.dequantize(t.data, t.tensor_type).astype(np.float32).reshape(M, K)

        use_a = (args.mode == "a"
                 and is_a_tensor(t.name, (M, K), args.include_output)
                 and (not args.only_q4k or tname.startswith("Q4_K")))
        if args.limit and n_a >= args.limit:
            use_a = False

        if use_a:
            idx, scl, w_exp = quantize(W, IQ4_NL)
            W = a_dequantize(idx, scl, w_exp, K)
            n_a += 1
            tag = f"A(w_exp={w_exp})"
        else:
            n_pass += 1
            tag = "pass"

        # Requantize to the storage type.  BOTH modes take this hit, which is
        # exactly why the control run exists to subtract it.
        wr.write_tensor_data(quants.quantize(W.reshape(M, K), out_qt))
        del W
        if (n_a + n_pass) % 40 == 0:
            print(f"  [{n_a+n_pass:4d}/{len(plan)}] {t.name:38s} {tname:6s} -> "
                  f"{args.out_type} {tag}", flush=True)

    print(f"  A-quantized {n_a}, passed through {n_pass}, verbatim {n_f32}")
    wr.close()
    print(f"wrote {args.dst}  ({os.path.getsize(args.dst)/2**30:.1f} GiB)")


if __name__ == "__main__":
    main()
