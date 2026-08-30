#!/usr/bin/env python3
"""THE DECISIVE ON-CARD TEST for the lane-stripe finding.  TRACK PACKSTRIPE.

    Does relocating ONE tensor's 27 sub-regions into 27 DISTINCT 256 MiB HBM
    segments take the 100-row K=4096 job's CYCLES from ~8,582 to under 1,500?

WHY THIS FILE EXISTS AND WHY IT IS NOT IN tools/ OR hw/fk33/host/.
`hw/fk33/host/fk33_run_job.py` builds the descriptor from
`manifest.hbm_offset + the .mv4i header's own sub-region table`, so all 27
bases are forced contiguous by construction and it CANNOT express a striped
placement.  Teaching it to would mean editing `hw/fk33/host/**`,
`tools/gen_mv4i_desc.py` and `tools/hbm_map.py`, which TRACK PACKSTRIPE does
not own.  So this file drives the existing, unmodified tools and applies the
relocation as an explicit extra step.  Same precedent as TRACK COUNTERS'
`2026-08-30_counters-tb_ctr_rate.vhd`: it lives under docs/debugging/ so it is
not a gate row and not a second host tool.

WHAT IT DOES NOT WEAKEN.  `make_plan()` runs FIRST and UNMODIFIED, so the
42-field cross-check between `tools/gen_mv4i_desc.py` (Python) and
`ref/mv_fk33_tr` (C) still has to agree on the FLAT descriptor before anything
moves -- including all 27 `w_base`/`s_base` values.  Only then is the
relocation applied, and it is checked in its own right: lane p's new base must
be the striped manifest's piece for lane p, and that piece's FILE offset must
equal the offset the two agreeing tools just derived.  So the striped
descriptor is the flat one plus a table this file proves it applied correctly,
rather than a descriptor nothing checked.

AND THE VALUES ARE STILL CHECKED.  `run_job()` compares every output row
against `ref/mv_fk33_tr`'s trace.  A relocation that lands one lane on the
wrong bytes computes a wrong y and FAILS -- which is the property that matters
most here, because subsystem A is proven bit-exact on this silicon over
1,675,264 rows and a placement change must not disturb that.

USAGE (see the write-up for the full two-arm procedure):

    python3 docs/debugging/2026-08-30_packstripe-stripe_probe.py \
        --mv4i  <STRIPED_DIR>/blk.0.ffn_gate.weight.mv4i \
        --flat-manifest    <FLAT_DIR>/manifest.json \
        --striped-manifest <STRIPED_DIR>/manifest.json \
        --rows 100 --x-exp -6 --slot 0 [--dry-run] [--no-copy]

`--dry-run` opens nothing under /dev.  It proves this file's plumbing and
NOTHING about any FPGA: `fk33_run_job.SimBar` REPLAYS the oracle.
"""
import argparse
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))

import gen_mv4i_desc as G                                     # noqa: E402
import fk33_run_job as R                                      # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mv4i", required=True)
    ap.add_argument("--flat-manifest", required=True,
                    help="the v1 manifest the tensor is RESIDENT under.  The "
                         "descriptor and every cross-check are built against "
                         "this one")
    ap.add_argument("--striped-manifest", required=True,
                    help="the v2 lane-striped manifest.  Read ONLY for the "
                         "27 piece addresses")
    ap.add_argument("--rows", type=int, default=None)
    ap.add_argument("--x-exp", type=int, default=-6)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--out-mode", type=int, default=1)
    ap.add_argument("--no-cb-load", action="store_true")
    ap.add_argument("--addr-w", type=int, default=40)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--xamp", type=int, default=None)
    ap.add_argument("--scratch", default=None)
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--show", type=int, default=8)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--flat", action="store_true",
                    help="CONTROL ARM.  Do not relocate and do not copy: run "
                         "exactly what fk33_run_job.py would run.  Use it to "
                         "take the baseline through this same file, so the "
                         "two CYCLES numbers differ in the placement and in "
                         "nothing else")
    ap.add_argument("--no-copy", action="store_true",
                    help="relocate the descriptor but do NOT write the 27 "
                         "sub-regions.  The bases then point at whatever is "
                         "resident, so the oracle comparison MUST fail.  It is "
                         "the teeth for the copy step: if this passes, the "
                         "engine is not reading where the descriptor says")
    a = ap.parse_args(argv)
    a.manifest = a.flat_manifest                 # what make_plan() reads

    regs = R.load_regs()
    scratch = R._scratch(a)

    # ---- 1. the FLAT plan, unmodified.  Every existing check runs here.
    p = R.make_plan(a, scratch)
    if not R.print_plan(p, regs):
        print("refusing: the two independent readings of the .mv4i header "
              "disagree", file=sys.stderr)
        return 2

    f = p["fields"]
    npw, nps = f["nsub_w"], f["nsub_s"]
    name = os.path.basename(a.mv4i)

    relo = []
    if not a.flat:
        # ---- 2. the relocation table, from the striped manifest's pieces
        sm = json.load(open(a.striped_manifest))
        if not sm.get("format", "").endswith("lane-striped"):
            print("refusing: %s is %r, not a lane-striped manifest"
                  % (a.striped_manifest, sm.get("format")), file=sys.stderr)
            return 2
        ent = next((e for e in sm["files"] if e.get("file") == name), None)
        if ent is None or not ent.get("pieces"):
            print("refusing: %s carries no pieces for %s"
                  % (a.striped_manifest, name), file=sys.stderr)
            return 2
        if ent["blake2b_128"] != p["digest_declared"]:
            print("refusing: the striped manifest's digest for %s is %s and "
                  "the flat manifest's is %s.  The two manifests do not "
                  "describe the same bytes, so the relocation would move a "
                  "DIFFERENT tensor."
                  % (name, ent["blake2b_128"], p["digest_declared"]),
                  file=sys.stderr)
            return 2
        by = {}
        for x in ent["pieces"]:
            if x["kind"] == "header":
                continue
            by[(x["kind"], x["lane"] if x["kind"] == "w" else x["lane"] - npw)] = x
        base0 = G.DESC_BASE0
        segs = set()
        for kind, n, wordbase in (("w", npw, base0), ("s", nps, base0 + npw)):
            for i in range(n):
                x = by.get((kind, i))
                if x is None:
                    print("refusing: no %s piece %d" % (kind, i), file=sys.stderr)
                    return 2
                old = p["desc"].words[wordbase + i]
                # THE TIE between the two artefacts.  `old - hbm_base` is the
                # sub-region offset that gen_mv4i_desc.py and ref/mv_fk33_tr
                # just AGREED on; the striped manifest's piece must be the
                # same sub-region, or this is relocating the wrong bytes.
                want = old - p["hbm_base"]
                if x["file_offset"] != want:
                    print("refusing: %s[%d] is at file +%d in the descriptor "
                          "and +%d in the striped manifest"
                          % (kind, i, want, x["file_offset"]), file=sys.stderr)
                    return 2
                if x["hbm_offset"] % 4096:
                    print("refusing: %s[%d] striped base 0x%X is not 4 KB "
                          "aligned; the gateware answers EC 0xC"
                          % (kind, i, x["hbm_offset"]), file=sys.stderr)
                    return 2
                # THE SEGMENT IS DERIVED FROM THE ADDRESS, NOT READ FROM THE
                # MANIFEST'S `segment` FIELD.  Teeth case T3 (two lanes given
                # the SAME hbm_offset) SURVIVED the first version of this
                # check, because that version counted the declared field and
                # the field was still 27 distinct values.  A check that reads a
                # label instead of the thing the hardware decodes is
                # decoration: address bits [32:28] are what select the
                # pseudo-channel.
                sg = x["hbm_offset"] // 0x1000_0000
                if sg != x["segment"]:
                    print("refusing: %s[%d] base 0x%X is in segment %d and the "
                          "manifest labels it %d"
                          % (kind, i, x["hbm_offset"], sg, x["segment"]),
                          file=sys.stderr)
                    return 2
                p["desc"].words[wordbase + i] = x["hbm_offset"]
                relo.append((kind, i, old, x["hbm_offset"], x["file_offset"],
                             x["nbytes"], sg))
                segs.add(sg)
        # keep fields in step so anything reading them sees the truth
        f["w_base"] = [p["desc"].words[base0 + i] for i in range(npw)]
        f["s_base"] = [p["desc"].words[base0 + npw + i] for i in range(nps)]
        print("\nRELOCATION  %d sub-regions -> %d DISTINCT 256 MiB segments %s"
              % (len(relo), len(segs), sorted(segs)))
        for kind, i, old, new, fo, nb, sg in relo[:3] + relo[-3:]:
            print("  %s[%2d]  0x%010X -> 0x%010X  seg %2d  file +%-9d %d B"
                  % (kind, i, old, new, sg, fo, nb))
        if len(segs) != npw + nps:
            print("refusing: %d distinct segments, wanted %d -- this would "
                  "NOT be the experiment" % (len(segs), npw + nps),
                  file=sys.stderr)
            return 2
        # ---- 3. would the gateware still take it?
        build = dict(G.FK33)
        build["addr_w"] = a.addr_w
        bad = G.rtl_would_reject(p["desc"], build=build,
                                 desc_addr=p["desc_addr"])
        if bad:
            print("refusing: the RELOCATED descriptor would be REFUSED by the "
                  "gateware:\n  " + "\n  ".join(str(b) for b in bad),
                  file=sys.stderr)
            return 2
        print("  gateware would ACCEPT the relocated descriptor "
              "(rtl_would_reject: no findings)")

    bar, hbm, sim = R.open_transport(a, regs, scratch, p)
    if sim:
        print("transport   SIMULATED.  Nothing under /dev is opened, and the "
              "model REPLAYS the oracle.  This says nothing about the card.")
    try:
        # ---- 4. put the bytes where the descriptor now points
        if relo and not a.no_copy:
            fd = os.open(a.mv4i, os.O_RDONLY)
            try:
                n = 0
                for kind, i, old, new, fo, nb, sg in relo:
                    buf = os.pread(fd, nb, fo)
                    if len(buf) != nb:
                        print("refusing: short read of %s[%d]" % (kind, i),
                              file=sys.stderr)
                        return 2
                    hbm.write(new, buf)
                    n += nb
            finally:
                os.close(fd)
            print("copied      %d B in %d sub-regions to the striped addresses"
                  % (n, len(relo)))
        elif relo:
            print("copied      NOTHING (--no-copy).  The bases point at "
                  "whatever is resident; the oracle comparison MUST fail.")

        verdict, detail = R.run_job(p, regs, bar, hbm, a)
    finally:
        bar.close()
        hbm.close()
    print("\nVERDICT     %s -- %s" % (verdict, detail))
    print("ARM         %s" % ("FLAT control" if a.flat else
                              "LANE-STRIPED, %d segments" % (npw + nps)))
    return {R.Verdict.PASS: 0, R.Verdict.FAIL: 1,
            R.Verdict.INCONCLUSIVE: 3, R.Verdict.REFUSED: 2}[verdict]


if __name__ == "__main__":
    sys.exit(main())
