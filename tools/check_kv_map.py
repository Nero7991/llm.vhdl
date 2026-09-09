#!/usr/bin/env python3
"""check_kv_map.py -- the mechanical link between the HBM address map's
AUTHORITY and subsystem C's KV generics.

    python3 tools/check_kv_map.py [--manifest PATH] [--no-manifest] [--teeth]

WHY THIS FILE EXISTS
====================
TRACK CKVMAP made subsystem C's real 9B KV map elaborate and then reported,
under its own name, a guard that does NOT bite:

    "`k_base_off_by_one_ch` says nothing in `llama_top` knows where the arena
     actually is.  The base is an input.  There is no link from the RTL to
     `hbm.kv_base`, so a base one chunk -- or one megabyte -- off the manifest
     elaborates clean and would read and write real weights.  The gate row
     pins the correct value, and THE GATE ROW IS THE ONLY THING THAT DOES."

and a second one:

    "a stale byte number under the new name (`-gC_V_BASE_CH=34816`)
     elaborates clean and means byte 557,056."

Neither can be closed inside the RTL.  282,598,913 is a perfectly legal chunk
count and so is 34,816; no assert over a generic can know which of them the
arena actually put the cache at, because the arena is not in the RTL.  What
CAN close both is a check that reads the two sides and refuses on mismatch,
and that is this file.  It is the only artefact in the tree that makes
`C_K_BASE_CH` a DERIVED quantity rather than a hand-copied one.

THE THREE SIDES IT READS, AND WHY EACH IS THE RIGHT SOURCE
=========================================================
  1. THE SHAPE.  `tools/hbm_map.py arena_sizes()`, which scrapes
     `rtl/model_cfg_pkg.vhd`.  TRACK ARENA-MANIFEST made `hbm_map.py`'s region
     block the authority for the HBM address map, so the record size, the KV
     head count and the attention layer count are taken from it and are never
     restated here.  In-repo, so this side always runs.
  2. THE PLACEMENT.  `hbm.kv_base` from the packed model's manifest.  This is
     the ONE number that no amount of in-repo arithmetic can produce, because
     it depends on where the weight image ended.  Out of tree, so a run
     without it says so LOUDLY and marks the rows NOT RUN rather than passing.
  3. THE RTL AND ITS BUILD CONFIGURATION.  `rtl/llama_top.vhd` for the generic
     NAMES, the record's own granule and the chunk-to-byte shift; and
     `sim/realshape_gate.sh`'s `real_kv_map` row for the VALUES, because the
     real map is a build configuration and not a default -- `C_MAXPOS`'s
     default cannot become 131,072 without sizing the behavioural cache at
     8.4 million signal entries (CKVMAP section 7).

WHAT IT DELIBERATELY DOES NOT DO
================================
It does not check that the RTL COMPUTES anything.  That is
`sim/tb_attn_kv_map.vhd`'s job and the two are complementary: this file says
the map points at the arena, that file says the map moves the right bytes.
Either alone is satisfied by a design that is wrong in the other way.
"""

import os
import re
import sys
import json

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

DEF_MANIFEST = ("/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/"
                "manifest.json")
LLAMA_TOP = os.path.join(REPO, "rtl", "llama_top.vhd")
GATE      = os.path.join(REPO, "sim", "realshape_gate.sh")

CH_B = 16          # the record granule, C spec 2.1.1


class Bad(Exception):
    pass


def clog2(n):
    r, v = 0, 1
    while v < n:
        v *= 2
        r += 1
    return r


# --------------------------------------------------------------------------
# side 3a: rtl/llama_top.vhd -- the NAMES, the granule and the ONE shift
# --------------------------------------------------------------------------
def read_rtl(path=LLAMA_TOP):
    src = open(path).read()
    out = {}

    # The generic names.  A rename must break this file loudly rather than
    # leave it checking something that no longer exists.
    for name in ("C_K_BASE_CH", "C_V_BASE_CH", "C_KV_ADDR_W", "C_MAXPOS",
                 "C_KV_BLOCK", "C_CM_W"):
        if not re.search(r"^\s*%s\s*:\s*\w+\s*:=" % name, src, re.M):
            raise Bad("rtl/llama_top.vhd declares no generic %s.  If it was "
                      "renamed, rename it here too -- do not delete the row."
                      % name)

    m = re.search(r"^\s*C_CM_W\s*:\s*\w+\s*:=\s*(\d+)", src, re.M)
    out["C_CM_W"] = int(m.group(1))

    # The shape must come from the SAME authority hbm_map.py scrapes.  If
    # llama_top ever stops deriving these from model_cfg_pkg, every identity
    # below is comparing two independent guesses.
    for decl, why in (
            (r"constant\s+C_HD\s*:\s*positive\s*:=\s*SHAPE\.attn_head_dim",
             "C_HD"),
            (r"constant\s+C_NKVH\s*:\s*positive\s*:=\s*SHAPE\.attn_kv_heads",
             "C_NKVH"),
            (r"constant\s+C_LAY\s*:\s*positive\s*:=\s*nlay\(SHAPE\)",
             "C_LAY")):
        if not re.search(decl, src):
            raise Bad("rtl/llama_top.vhd no longer derives %s from SHAPE.  "
                      "hbm_map.py's numbers and llama_top's would then be two "
                      "independent guesses at the same shape." % why)

    # THE CHUNK-TO-BYTE SEAM.  rtl/llama_top.vhd holds the bases in 16-byte
    # chunks because the byte value does not fit a `natural`, and shifts back
    # to bytes at the port map.  That shift is the one place a silent 16x
    # address error can be introduced, so its AMOUNT is read out of the source
    # and checked against the granule rather than assumed to be 4.
    seam = {}
    for gen, sig in (("C_K_BASE_CH", "KBASE_C"), ("C_V_BASE_CH", "VBASE_C")):
        m = re.search(
            r"constant\s+%s\s*:.*?shift_left\(\s*to_unsigned\(\s*%s\s*,"
            r"\s*C_KV_ADDR_W\s*\)\s*,\s*(\d+)\s*\)" % (sig, gen),
            src, re.S)
        if not m:
            raise Bad(
                "rtl/llama_top.vhd: could not find the chunk-to-byte shift "
                "that builds %s from %s.  attn_kv_axi's k_base/v_base are "
                "BYTE addresses (its rec_addr adds idx*REC_B with REC_B in "
                "bytes) and the generic is a CHUNK count, so a shift must "
                "exist at the port map.  If it moved, this check must move "
                "with it -- a missing shift is a 16x address error that "
                "elaborates perfectly cleanly." % (sig, gen))
        seam[sig] = int(m.group(1))
    out["shift"] = seam

    # and the two constants must actually reach the instance
    if not re.search(r"k_base\s*=>\s*KBASE_C\s*,\s*v_base\s*=>\s*VBASE_C",
                     src):
        raise Bad("rtl/llama_top.vhd: KBASE_C/VBASE_C are not the actuals of "
                  "attn_kv_axi's k_base/v_base any more.  The shift they "
                  "carry is then not on the path the cache uses.")
    return out


# --------------------------------------------------------------------------
# side 3b: sim/realshape_gate.sh -- the VALUES of the build configuration
# --------------------------------------------------------------------------
def read_gate(path=GATE):
    src = open(path).read()
    m = re.search(r"^KVR=\"-g.*?$(?:\nKVR=\"\$KVR[^\n]*)*", src, re.M)
    if not m:
        raise Bad("sim/realshape_gate.sh: no KVR= block.  That block IS the "
                  "real map's build configuration; without it there is "
                  "nothing on the RTL side to compare.")
    blk = m.group(0)
    out = {}
    for k, v in re.findall(r"-g(C_\w+)=(-?\d+)", blk):
        out[k] = int(v)
    for need in ("C_K_BASE_CH", "C_V_BASE_CH", "C_KV_ADDR_W", "C_MAXPOS",
                 "C_KV_BLOCK"):
        if need not in out:
            raise Bad("sim/realshape_gate.sh's KVR block does not set %s"
                      % need)
    # and the row that uses it must still be an `ok` row
    if not re.search(r"^row\s+real_kv_map\s+ok\s+llama_top\b.*\$KVR",
                     src, re.M):
        raise Bad("sim/realshape_gate.sh: the `real_kv_map ok` row no longer "
                  "uses $KVR, so these values are not the ones anything "
                  "elaborates.")
    return out


# --------------------------------------------------------------------------
# the check itself
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# side 4: hw/fk33/gen_fk33_card.py -- WHAT THE HARDWARE ACTUALLY GETS
#
# MEASURED 2026-09-09, and this side exists because of it: every other row in
# this file was GREEN while the card build instantiated `llama_top`'s DEFAULTS
# -- C_MAXPOS 4, C_CTXLEN 1, C_K_BASE_CH 1, C_V_BASE_CH 254, C_KV_ADDR_W 16.
# The KVR block in sim/realshape_gate.sh carried the real 9B values and was
# checked against the manifest to zero slack, so the geometry was pinned for
# SIMULATION and nothing whatsoever linked it to the geometry that gets built.
#
# The symptom reached the block design as twenty
# `CRITICAL WARNING: [BD 41-2383] Width mismatch ... Only lower order bits
# will be connected`, silently truncating C's KV address from 33 bits to 16.
# The build gates on `^ERROR` and a CRITICAL WARNING is not one, so it passed.
#
# This is the "guard that passes for the wrong reason" class one level up: the
# guard was correct and was checking a different artifact than the one that
# ships.  A checker that validates the simulation configuration says nothing
# about the hardware configuration unless something asserts they are equal.
# --------------------------------------------------------------------------
CARD_GEN = os.path.join(REPO, "hw", "fk33", "gen_fk33_card.py")


def read_card(path=CARD_GEN):
    src = open(path).read()
    out = {}
    for k, v in re.findall(r'"--generic",\s*"(C_\w+)=(-?\d+)"', src):
        out[k] = int(v)
    return out


def check(manifest_path=DEF_MANIFEST, require_manifest=True, out=sys.stdout,
          rtl_over=None, gate_over=None, sz_over=None, mani_over=None):
    import hbm_map as H

    sz = dict(H.arena_sizes())
    if sz_over:
        sz.update(sz_over)
    rtl = read_rtl()
    if rtl_over:
        rtl.update(rtl_over)
    gate = read_gate()
    if gate_over:
        gate.update(gate_over)

    mani = None
    if manifest_path and os.path.exists(manifest_path):
        mani = json.load(open(manifest_path))["hbm"]
    if mani_over is not None:
        mani = dict(mani or {})
        mani.update(mani_over)

    rows = []

    def row(name, ok, detail):
        rows.append((name, ok, detail))

    HD    = sz["attn_head_dim"]
    NKVH  = sz["kv_heads_per_card"]
    LAY   = sz["attn_layers"]
    REC_B = sz["kv_record_bytes"]
    PERTOK = sz["kv_bytes_per_token"]

    K   = gate["C_K_BASE_CH"]
    V   = gate["C_V_BASE_CH"]
    AW  = gate["C_KV_ADDR_W"]
    MP  = gate["C_MAXPOS"]
    KVB = gate["C_KV_BLOCK"]

    # ---- the granule, and the record ------------------------------------
    row("record granule divides", REC_B % CH_B == 0,
        "kv_record_bytes %d %% %d = %d" % (REC_B, CH_B, REC_B % CH_B))
    row("record = header + HEAD_DIM*CM_W/8",
        REC_B == CH_B + HD * rtl["C_CM_W"] // 8,
        "%d vs %d + %d*%d/8 = %d"
        % (REC_B, CH_B, HD, rtl["C_CM_W"],
           CH_B + HD * rtl["C_CM_W"] // 8))
    row("header fits the granule", (HD // KVB) * 8 // 8 <= CH_B,
        "NBLK %d exponent bytes into a %d-byte header chunk"
        % (HD // KVB, CH_B))
    row("KV block divides HEAD_DIM and leaves >= 2 blocks",
        HD % KVB == 0 and HD // KVB >= 2,
        "HEAD_DIM %d / C_KV_BLOCK %d = %d blocks" % (HD, KVB, HD // KVB))
    row("per-layer per-token bytes = 2*N_KVH*REC_B",
        sz["kv_bytes_per_layer_per_token"] == 2 * NKVH * REC_B,
        "%d vs 2*%d*%d = %d" % (sz["kv_bytes_per_layer_per_token"],
                                NKVH, REC_B, 2 * NKVH * REC_B))

    # ---- THE CHUNK-TO-BYTE SEAM -----------------------------------------
    want_shift = clog2(CH_B)
    for sig, got in sorted(rtl["shift"].items()):
        if got == want_shift:
            why = "the byte address is the chunk count times the granule"
        else:
            why = ("the cache would sit at 2**%d times the arena base, and "
                   "that elaborates perfectly cleanly" % (got - want_shift))
        row("llama_top %s shifts by log2(granule)" % sig, got == want_shift,
            "shift_left(..., %d), want %d = log2(%d) -- %s"
            % (got, want_shift, CH_B, why))

    # ---- THE LINK THAT DID NOT EXIST ------------------------------------
    REC_CH = REC_B // CH_B
    region_ch = LAY * NKVH * MP * REC_CH

    if mani is not None:
        kv_base = int(mani["kv_base"])
        row("C_K_BASE_CH*16 == manifest hbm.kv_base", K * CH_B == kv_base,
            "%d * %d = %d vs kv_base %d  (delta %d bytes)"
            % (K, CH_B, K * CH_B, kv_base, K * CH_B - kv_base))
        row("manifest kv_record_bytes agrees with the shape",
            int(mani["kv_record_bytes"]) == REC_B,
            "%s vs %d" % (mani["kv_record_bytes"], REC_B))
        row("manifest kv_layers agrees with the shape",
            int(mani["kv_layers"]) == LAY, "%s vs %d"
            % (mani["kv_layers"], LAY))
        row("manifest kv_bytes_per_token agrees with the shape",
            int(mani["kv_bytes_per_token"]) == PERTOK,
            "%s vs %d" % (mani["kv_bytes_per_token"], PERTOK))
        row("C_V_BASE_CH*16 == kv_base + (bytes_per_token/2)*C_MAXPOS",
            V * CH_B == kv_base + (PERTOK // 2) * MP,
            "%d vs %d + %d*%d = %d"
            % (V * CH_B, kv_base, PERTOK // 2, MP,
               kv_base + (PERTOK // 2) * MP))
        end_b = (V + region_ch) * CH_B
        ceil_b = int(mani["desc_arena_base"])
        row("the K+V region ends below desc_arena_base", end_b <= ceil_b,
            "region ends at %d, descriptor arena starts at %d, margin %d bytes"
            % (end_b, ceil_b, ceil_b - end_b))
    else:
        row("MANIFEST NOT READ", None,
            "no manifest at %s.  hbm.kv_base is the one number no in-repo "
            "arithmetic can produce -- it depends on where the weight image "
            "ended -- so the rows that pin C_K_BASE_CH to the arena DID NOT "
            "RUN.  Pass --manifest PATH." % manifest_path)

    # ---- the two regions, and the address width -------------------------
    row("V region starts where K's ends", V == K + region_ch,
        "%d vs %d + %d*%d*%d*%d = %d"
        % (V, K, LAY, NKVH, MP, REC_CH, K + region_ch))
    row("K and V do not overlap",
        K + region_ch <= V or V + region_ch <= K,
        "each region is %d chunks; bases %d and %d" % (region_ch, K, V))
    need = clog2(max(K, V) + region_ch)
    row("C_KV_ADDR_W - 4 >= clog2(top chunk)", AW - clog2(CH_B) >= need,
        "clog2(%d) = %d, C_KV_ADDR_W - %d = %d  (slack %d bit(s))"
        % (max(K, V) + region_ch, need, clog2(CH_B), AW - clog2(CH_B),
           AW - clog2(CH_B) - need))

    # ---- side 4: the built geometry must equal the simulated geometry ----
    try:
        card = read_card()
    except OSError as e:
        row("hw/fk33/gen_fk33_card.py is readable", False, str(e))
        card = None
    if card is not None:
        for name in ("C_KV_BLOCK", "C_K_BASE_CH", "C_V_BASE_CH",
                     "C_KV_ADDR_W", "C_MAXPOS", "C_CTXLEN"):
            want = gate.get(name)
            got  = card.get(name)
            if want is None:
                row("gen_fk33_card %s has an authority" % name, False,
                    "sim/realshape_gate.sh's KVR block does not set %s, so "
                    "there is nothing to compare the build against" % name)
            elif got is None:
                row("gen_fk33_card sets %s" % name, False,
                    "hw/fk33/gen_fk33_card.py passes no --generic %s, so the "
                    "card cell is built with llama_top's DEFAULT and not the "
                    "9B value %d.  This is the 2026-09-09 defect." % (name, want))
            else:
                row("gen_fk33_card %s == KVR %s" % (name, name), got == want,
                    "built %d vs simulated %d%s"
                    % (got, want, "" if got == want else "  <-- DIVERGED"))

    nfail = sum(1 for _, ok, _ in rows if ok is False)
    nskip = sum(1 for _, ok, _ in rows if ok is None)
    w = max(len(n) for n, _, _ in rows)
    for name, ok, detail in rows:
        tag = "ok    " if ok else ("NOT RUN" if ok is None else "REFUSED")
        out.write("  %-7s %-*s  %s\n" % (tag, w, name, detail))
    out.write("check_kv_map: %d rows, %d refused, %d not run\n"
              % (len(rows), nfail, nskip))
    if nskip and require_manifest:
        out.write("check_kv_map: REFUSING -- the placement side did not run "
                  "and --no-manifest was not given.  A check that silently "
                  "skips its only external input is decoration.\n")
        return 2
    return 1 if nfail else 0


# --------------------------------------------------------------------------
# teeth.  A checker never shown to refuse has not been shown to work.
# --------------------------------------------------------------------------
def teeth(manifest_path):
    import io
    cases = [
        ("control", {}, False),
        ("k_base_one_chunk_high", dict(gate_over={"C_K_BASE_CH": 282598913}),
         True),
        ("k_base_one_chunk_low", dict(gate_over={"C_K_BASE_CH": 282598911}),
         True),
        ("k_base_a_stale BYTE number under the _CH name",
         dict(gate_over={"C_K_BASE_CH": 4521582592}), True),
        ("v_base_the CKVMAP stale byte 34816",
         dict(gate_over={"C_V_BASE_CH": 34816}), True),
        ("v_base_one_chunk_high", dict(gate_over={"C_V_BASE_CH": 353902081}),
         True),
        ("maxpos_halved", dict(gate_over={"C_MAXPOS": 65536}), True),
        ("addr_w_one_short", dict(gate_over={"C_KV_ADDR_W": 32}), True),
        ("kv_block_illegal", dict(gate_over={"C_KV_BLOCK": 3}), True),
        ("the seam shifts by 3", dict(rtl_over={"shift": {"KBASE_C": 3,
                                                          "VBASE_C": 4}}),
         True),
        ("the seam shifts by 5", dict(rtl_over={"shift": {"KBASE_C": 4,
                                                          "VBASE_C": 5}}),
         True),
        ("the seam does not shift", dict(rtl_over={"shift": {"KBASE_C": 0,
                                                             "VBASE_C": 0}}),
         True),
        ("the arena moved by one page",
         dict(mani_over={"kv_base": 4521586688}), True),
        ("the model grew a KV head",
         dict(sz_over={"kv_heads_per_card": 8}), True),
        ("the model grew an attention layer",
         dict(sz_over={"attn_layers": 9}), True),
        ("the record lost a byte", dict(sz_over={"kv_record_bytes": 271}),
         True),
        ("C_CM_W doubled", dict(rtl_over={"C_CM_W": 16}), True),
    ]
    npass = nmiss = 0
    print("==== teeth for tools/check_kv_map.py ====")
    for name, kw, want_refuse in cases:
        buf = io.StringIO()
        rc = check(manifest_path, require_manifest=True, out=buf, **kw)
        refused = rc != 0
        if refused == want_refuse:
            npass += 1
            verdict = "REFUSED" if refused else "accepted"
        else:
            nmiss += 1
            verdict = ("DID NOT REFUSE -- THIS IS A HOLE"
                       if want_refuse else "REFUSED THE CONTROL")
        line = ""
        for ln in buf.getvalue().splitlines():
            if ln.strip().startswith("REFUSED"):
                line = ln.strip()
                break
        print("  %-46s %s" % (name, verdict))
        if line:
            print("        %s" % line[:170])
    print("---- %d of %d teeth rows behaved as intended ----"
          % (npass, npass + nmiss))
    return 0 if nmiss == 0 else 1


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=DEF_MANIFEST)
    ap.add_argument("--no-manifest", action="store_true",
                    help="run the in-repo rows only, and say so; still "
                         "refuses on any in-repo mismatch")
    ap.add_argument("--teeth", action="store_true")
    a = ap.parse_args(argv)
    if a.teeth:
        return teeth(a.manifest)
    try:
        return check(a.manifest, require_manifest=not a.no_manifest)
    except Bad as e:
        sys.stderr.write("check_kv_map: REFUSING -- %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
