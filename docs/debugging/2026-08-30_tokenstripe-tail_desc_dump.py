#!/usr/bin/env python3
"""Dump the 15 lm-head window descriptors hw/fk33/host/fk33_run_token.py's
`make_tail` + its build_descriptor call site (line ~1103) would build.

MIRRORS that call site exactly.  `pieces=getattr(j, "pieces", None)` is None on
the pre-change file, so ONE harness runs against both revisions."""
import os, sys, json
REPO = os.environ.get("TS_REPO", "/home/orencollaco/GitHub/llama.vhdl")
sys.path.insert(0, os.path.join(REPO, "hw/fk33/host"))
sys.path.insert(0, os.path.join(REPO, "tools"))
import gen_mv4i_desc as G
import fk33_run_layer as RL
import fk33_run_token as RT
import gen_layer_program as L


class A:
    pass


def main():
    mani, out = sys.argv[1], sys.argv[2]
    xe = -6
    s = L.QWEN35_9B
    a0 = A(); a0.manifest, a0.layer, a0.ref_manifest = mani, 0, None
    p0 = RL.make_layer(a0)
    a = A(); a.manifest, a.ref_manifest = mani, None
    tail = RT.make_tail(a, s, 0, p0["arena_base"], p0["stride"], p0["n_slots"])
    rows = []
    npieces = nflat = 0
    for j in tail["jobs"]:
        pieces = getattr(j, "pieces", None)
        if pieces is None:
            nflat += 1
        else:
            npieces += 1
        d = G.build_descriptor(
            tail["header"], j.hbm_offset, j.n_rows, xe,
            out_mode=j.out_mode, cb_load=True, addr_w=40,
            row_start=j.row_start, src_region=j.src_region,
            dst_region=j.dst_region, dst_offset=j.dst_off, ordinal=j.ordinal,
            src_region2=j.src2, const_base=j.const_base, const_exp=0,
            **({} if pieces is None else dict(pieces=pieces)))
        rows.append(dict(idx=j.idx, tensor=j.tensor, short=j.short,
                         row_start=j.row_start, n_rows=j.n_rows,
                         hbm_offset=j.hbm_offset,
                         words=["%016X" % w for w in d.words],
                         w_base=d.fields["w_base"],
                         s_base=d.fields["s_base"]))
    with open(out, "w") as fp:
        json.dump(rows, fp, indent=0, sort_keys=True)
    nw = sum(len(r["words"]) for r in rows)
    nb = sum(len(r["w_base"]) + len(r["s_base"]) for r in rows)
    print("windows %d  words %d  sub-region bases %d" % (len(rows), nw, nb))
    print("jobs with pieces %d  jobs flat %d" % (npieces, nflat))
    print("mv4i %s" % tail["mv4i"])


if __name__ == "__main__":
    sys.exit(main())
