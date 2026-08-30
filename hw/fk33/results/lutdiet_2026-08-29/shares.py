#!/usr/bin/env python3
"""TRACK LUTDIET: the flat-storage share of B and C, computed from the censuses
rather than asserted.  The root lists below are the roots that name a flat
staging vector or a variable-index access to one; each was checked back to the
RTL line that declares or indexes it, and the RTL line is in the comment."""
import sys, os
OUT = sys.argv[1] if len(sys.argv) > 1 else "."

FLAT = {
 "gdn_none": {                     # rtl/gdn_block.vhd
   "qsb":    "qsb  32,768b staging, :378 ; written :889 ; read :979",
   "knb":    "knb  32,768b staging, :377 ; written :891 ; read :978",
   "vbuf":   "vbuf 65,536b staging, :376 ; written :725 ; read :1046 (4096:1)",
   "kbuf":   "kbuf 32,768b staging, :375 ; written :723 ; read :880",
   "qbuf":   "qbuf 32,768b staging, :374 ; written :721 ; read :878",
   "l2_x":   "l2_x  2,048b, the 16:1-of-2048b read off qbuf/kbuf, :423/:878",
   "rp_cvj": "the 4096:1 16-bit read off vbuf, :1046",
   "rp_qs":  "rp_qs 2,048b, the 16:1 read off qsb, :443/:979",
   "rp_kn":  "rp_kn 2,048b, the 16:1 read off knb, :442/:978",
   "q":      "u_l2/q_reg,  l2norm_rs's own flat output register",
   "k":      "u_l2/k_reg,  l2norm_rs's own flat output register",
   "o":      "u_emit/u_head/o_reg, gdn_head_emit's own flat output register",
 },
 "attn_none": {                    # rtl/attn_block.vhd
   "qplane": "qplane G*HEAD_DIM*MANT_W = 16,384b, :410",
   "krec":   "krec  HEAD_DIM*CM_W = 4,096b, :415 ; written :1086/:1103",
   "vrec":   "vrec  HEAD_DIM*CM_W = 4,096b, :415 ; written :1088/:1100",
   "o":      "u_norm/o_reg, the embedded rmsnorm_rs's flat output register",
   "vs":     "vs, per-head flat value staging",
   "rn_w":   "rn_w  HEAD_DIM*MANT_W = 4,096b norm gain, :436",
   "vs2_q":  "the variable-index read off vs2",
   "ARG":    "u_norm/ARG, the embedded rmsnorm_rs's x_mant/w_mant read mux",
   "kw_mant":"kw_mant KV_BLOCK*CM_W, :309",
   "sq":     "u_norm/sq, the embedded rmsnorm_rs's S_ACC read mux",
   "vs_q":   "the variable-index read off vs",
   "vs2":    "vs2, per-head flat value staging",
 },
}
for tag, roots in FLAT.items():
    p = os.path.join(OUT, "census_%s.txt" % tag)
    if not os.path.exists(p): continue
    tot = 0; hit = {}
    for line in open(p):
        if line.startswith("#") or line.startswith("root"): continue
        f = line.split()
        if len(f) < 6: continue
        try: n = int(f[1])
        except ValueError: continue
        tot += n
        if f[0] in roots: hit[f[0]] = n
    s = sum(hit.values())
    print("\n== %s : flat-storage share of LUT primitives ==" % tag)
    for k in sorted(hit, key=lambda k: -hit[k]):
        print("  %-10s %9d   %s" % (k, hit[k], roots[k]))
    print("  %-10s %9d of %d = %.1f%%" % ("TOTAL", s, tot, 100.0 * s / tot))
    missing = set(roots) - set(hit)
    if missing: print("  (roots named but not present in this census: %s)" % ", ".join(sorted(missing)))

# ---------------------------------------------------------------------------
# The flat cost splits into a WRITE demux and a READ mux, and they respond to
# DIFFERENT fixes.  The write demux is removable by a coding change alone
# (rmsnorm_rs_hotw: same ports, no memory, no schedule change).  The read mux
# needs an actual memory.  Which roots are which is read off the RTL, not
# guessed: a root named for the staging vector itself is its variable-index
# WRITE; a root named for the destination of a slice READ is the mux.
# ---------------------------------------------------------------------------
WRITE = {
 "gdn_none":  ["qsb", "knb", "vbuf", "kbuf", "qbuf", "q", "k", "o"],
 "attn_none": ["qplane", "krec", "vrec", "o", "vs", "rn_w", "kw_mant", "vs2"],
}
READ = {
 "gdn_none":  ["l2_x", "rp_cvj", "rp_qs", "rp_kn"],
 "attn_none": ["vs2_q", "ARG", "sq", "vs_q"],
}
print()
for tag in ("gdn_none", "attn_none"):
    p = os.path.join(OUT, "census_%s.txt" % tag)
    if not os.path.exists(p): continue
    tot = 0; v = {}
    for line in open(p):
        if line.startswith("#") or line.startswith("root"): continue
        f = line.split()
        if len(f) < 6: continue
        try: n = int(f[1])
        except ValueError: continue
        tot += n; v[f[0]] = v.get(f[0], 0) + n
    w = sum(v.get(k, 0) for k in WRITE[tag])
    rd = sum(v.get(k, 0) for k in READ[tag])
    print("%-10s write-demux %7d (%.1f%%)   read-mux %6d (%.1f%%)   other %7d (%.1f%%)  of %d" % (
        tag, w, 100.0*w/tot, rd, 100.0*rd/tot, tot-w-rd, 100.0*(tot-w-rd)/tot, tot))
