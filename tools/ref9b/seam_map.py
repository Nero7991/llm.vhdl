#!/usr/bin/env python3
"""RTL seam name -> llama.cpp node name, with the slice where they differ.

THE NAMES ON THE LEFT ARE THE RTL'S, NOT THE SPEC'S.  They are the region
names in `rtl/llama_map_pkg.vhd` (R_X, R_XN, R_QKV, R_Z, R_BETA, R_ALPHA,
R_QG, R_KIN, R_VIN, R_Y, R_G, R_U, R_H, R_ER), because a region is what the
hardware can actually be asked for: `hr_reg`/`hr_addr`/`hr_data`
(rtl/llama_top.vhd:483-485, combinational at :1005) reads any element of any
region, and the descriptor table in `sim/seq_tbl_pkg.vhd` is written in exactly
these names.  A seam named after a spec unit would be a seam nothing can
capture.

The suffix disambiguates the two uses a region gets inside one block, since the
RTL reuses R_XN and R_ER for both the attention/GDN half and the FFN half:

    R_XN-L      the block's pre-norm output   (OP_VEC_NORM, first)
    R_XN.ffn-L  the FFN's pre-norm output     (OP_VEC_NORM, second)
    R_ER-L      the B or C output projection  (OP_A_JOB into R_ER, first)
    R_ER.ffn-L  ffn_down                      (OP_A_JOB into R_ER, second)
    R_X.attn-L  R_X after the first residual  (OP_VEC_RES, first)
    R_X-L       R_X after the FFN residual    (OP_VEC_RES, second)

WHERE THE TWO SIDES DISAGREE STRUCTURALLY, and it is not cosmetic:

 1. R_QKV is THREE subsystem A jobs at packed rows 0 / 2064 / 4128, each with
    its OWN block exponent, because a row window has to start on a tile
    boundary and 2048 mod 48 != 0.  llama.cpp has one contiguous 8192 tensor
    with segments at 0 / 2048 / 4096.  So the map slices the anchor, and the
    hardware's three exponents have no counterpart on the anchor side at all.
 2. R_QG is 8192 rows INTERLEAVED PER HEAD -- [h0 q(256) | h0 gate(256) | h1
    q(256) | ...] -- fixed by llama.cpp's two ggml_view_3d calls with row
    stride 2*head_dim.  The anchor's Qcur_full-L has the same layout, so the
    map is 1:1, but anything downstream that reads it as [all q | all gate]
    is wrong on every head but the first.
 3. R_KIN / R_VIN are the RAW k and v projections, before the k norm and
    before RoPE.  llama.cpp names the pre-norm and post-RoPE tensors BOTH
    `Kcur-L`; the pre-norm one is the first occurrence and is what maps here.
 4. TOKEN has anchor `None`.  It is the argmax `rtl/sampler_stream.vhd`
    produces, and llama.cpp's graph has no node for it -- sampling happens
    outside the graph the `cb_eval` hook can see.  So it is a seam with an RTL
    side and no anchor side, and `--mode cross` skips it rather than reporting
    it missing.

THIS MAP IS THE 9B MODEL'S, AND IT IS NOT A SHAPE-GENERIC SCHEDULE.
`ATTN_INT` is 4 here because that is the real model's interleave, and the
anchor names on the right are llama.cpp's for that model, so the map cannot be
anything else.  A SCALED simulation at `ATTN_INT = 2` therefore produces names
this map does not contain (`R_QG-1`, `R_KIN-1`, `R_VIN-1`).  Until 2026-08-29
`seam_bisect.exact()` WALKED THIS LIST, so those seams were present in both
streams, modelled, and silently never compared -- 57 modelled, 54 compared, and
the verdict line read like full coverage.  `exact()` now walks the intersection
of the two streams instead and this map only orders the walk.  `cross()` still
needs it, because a cross-format comparison is against the 9B anchor by
definition.
"""

N_LAYER, ATTN_INT = 32, 4


def is_attn(il: int) -> bool:
    return (il + 1) % ATTN_INT == 0


def build():
    """[(rtl_name, anchor_name, offset, length_or_None)] in execution order."""
    m = [("R_X.embed", "model.input_embed", 0, None)]
    for L in range(N_LAYER):
        m.append(("R_XN-%d" % L, "attn_norm-%d" % L, 0, None))
        if is_attn(L):
            m += [("R_QG-%d"  % L, "Qcur_full-%d" % L, 0, None),
                  ("R_KIN-%d" % L, "Kcur-%d" % L, 0, None),
                  ("R_VIN-%d" % L, "Vcur-%d" % L, 0, None),
                  ("R_Y-%d"   % L, "attn_gated-%d" % L, 0, None),
                  ("R_ER-%d"  % L, "attn_output-%d" % L, 0, None)]
        else:
            m += [("R_QKV.q-%d" % L, "linear_attn_qkv_mixed-%d" % L, 0,    2048),
                  ("R_QKV.k-%d" % L, "linear_attn_qkv_mixed-%d" % L, 2048, 2048),
                  ("R_QKV.v-%d" % L, "linear_attn_qkv_mixed-%d" % L, 4096, 4096),
                  ("R_Z-%d"     % L, "z-%d" % L, 0, None),
                  ("R_BETA-%d"  % L, "beta-%d" % L, 0, None),
                  ("R_ALPHA-%d" % L, "alpha-%d" % L, 0, None),
                  ("R_Y-%d"     % L, "final_output-%d" % L, 0, None),
                  ("R_ER-%d"    % L, "linear_attn_out-%d" % L, 0, None)]
        m += [("R_X.attn-%d"  % L, "attn_residual-%d" % L, 0, None),
              ("R_XN.ffn-%d"  % L, "attn_post_norm-%d" % L, 0, None),
              ("R_G-%d"       % L, "ffn_gate-%d" % L, 0, None),
              ("R_U-%d"       % L, "ffn_up-%d" % L, 0, None),
              ("R_H-%d"       % L, "ffn_swiglu-%d" % L, 0, None),
              ("R_ER.ffn-%d"  % L, "ffn_out-%d" % L, 0, None),
              ("R_X-%d"       % L, "l_out-%d" % L, 0, None)]
    m += [("R_XN.final", "result_norm", 0, None),
          ("LOGITS",     "result_output", 0, None),
          ("TOKEN",      None, 0, None)]
    return m


SEAMS = build()

if __name__ == "__main__":
    for a, b, o, n in SEAMS:
        print("%-16s <- %-26s off=%-5d len=%s"
              % (a, b if b else "(no anchor node)", o, n if n else "all"))
