#!/usr/bin/env python3
"""Dump every descriptor hw/fk33/host/fk33_run_layer.py would build, for every
layer, as hex words.  MIRRORS the call site at fk33_run_layer.py:995 exactly;
`pieces=getattr(j, "pieces", None)` is None on the pre-change file, so the same
harness runs against both revisions."""
import os, sys, json
REPO = os.environ.get("SP_REPO", "/home/orencollaco/GitHub/llama.vhdl")
sys.path.insert(0, os.path.join(REPO, "hw/fk33/host"))
sys.path.insert(0, os.path.join(REPO, "tools"))
import gen_mv4i_desc as G
import fk33_run_layer as RL


class A:
    pass


def main():
    mani = sys.argv[1]
    out = sys.argv[2]
    xe = -6
    blocks = RL.L.QWEN35_9B.blocks
    rows = []
    npieces = nflat = 0
    for layer in range(blocks):
        a = A()
        a.manifest, a.layer, a.ref_manifest = mani, layer, None
        plan = RL.make_layer(a)
        for j in plan["jobs"]:
            pieces = getattr(j, "pieces", None)
            if pieces is None:
                nflat += 1
            else:
                npieces += 1
            d = G.build_descriptor(
                G.Mv4iHeader(j.mv4i), j.hbm_offset, j.n_rows, xe,
                out_mode=j.out_mode, cb_load=True, addr_w=40,
                row_start=j.row_start, src_region=j.src_region,
                dst_region=j.dst_region, dst_offset=j.dst_off,
                ordinal=j.ordinal, src_region2=j.src2,
                const_base=j.const_base, const_exp=0,
                **({} if pieces is None else dict(pieces=pieces)))
            rows.append(dict(layer=layer, idx=j.idx, tensor=j.tensor,
                             row_start=j.row_start, n_rows=j.n_rows,
                             hbm_offset=j.hbm_offset,
                             words=["%016X" % w for w in d.words],
                             w_base=d.fields["w_base"],
                             s_base=d.fields["s_base"]))
    with open(out, "w") as fp:
        json.dump(rows, fp, indent=0, sort_keys=True)
    nw = sum(len(r["words"]) for r in rows)
    nb = sum(len(r["w_base"]) + len(r["s_base"]) for r in rows)
    print("layers %d  descriptors %d  words %d  sub-region bases %d"
          % (blocks, len(rows), nw, nb))
    print("jobs with pieces %d  jobs flat %d" % (npieces, nflat))


if __name__ == "__main__":
    sys.exit(main())
