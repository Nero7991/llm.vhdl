#!/usr/bin/env python3
"""check_kv_map.py -- the mechanical link between the HBM address map's
AUTHORITY and subsystem C's KV generics.

    python3 tools/check_kv_map.py [--manifest PATH] [--striped-manifest PATH]
                                  [--no-manifest] [--teeth]

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

THE FOUR SIDES IT READS, AND WHY EACH IS THE RIGHT SOURCE
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
  4. WHAT IS ACTUALLY BUILT.  `hw/fk33/rtl/fk33_card.vhd`, the COMMITTED
     artifact that `gen_pcieep.py` puts in the build's `read_vhdl` list.  NOT
     `hw/fk33/gen_fk33_card.py`, which is what this side read until
     2026-09-20 and which the `FK33_C_KV_BLOCK` env trim is designed to leave
     untouched -- see the long comment above `card_generic_map`.

THE ROWS ADDED 2026-09-20, AND THE DEFECT THEY WOULD HAVE CAUGHT
================================================================
Every row above pins the DEFAULT generics to ONE manifest, the flat one.
MEASURED 2026-09-20 on silicon (docs/debugging/2026-09-20_the-kv-cache-base-
is-compiled-into-the-bitstream.md): the loaded image was the lane-STRIPED
one, whose kv_base is 0x1AD71C000, and the bitstream carried the flat pair
compiled in; every C job wrote its records into weight pieces, 40 objects.
This gate was green the whole time, because it was asked about the flat
manifest and answered correctly about it.

So the geometry is now checked against BOTH manifests, at the CARD's
C_MAXPOS, with K = hbm.kv_base and V = K + C_MAXPOS * kv_bytes_per_token/2
-- which is what the host now programs into the seam (A_KVK/A_KVV) -- and
the pair's whole extent must lie inside hbm.size, intersect no piece of any
file (striped entries carry `pieces`; flat entries carry hbm_offset/nbytes),
and intersect none of gdn_state, gdn_const and the descriptor arena.  The
teeth row `striped_image_with_the_compiled_flat_pair_at_131072` IS the
2026-09-20 defect, and its attribution control (the same mutant with these
rows disabled) shows the older rows were blind to it.

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
# THE LANE-STRIPED IMAGE TO LOAD, CHANGED 2026-09-20 BY TRACK ARENAPLACE.
# `.../qwen35-9b-mv4i-noembd-striped` -- the image that was loaded on the card
# -- has its GDN state and the first 2,463 tokens of its KV cache on segment
# 26, a pseudo-channel six weight lanes read, because `hbm_map.write_arenas()`
# re-placed them with a 4 KB round-up after the packer had placed them at the
# segment boundary.  `-striped-seg27` is the same 250 packed files (every
# per-file blake2b equal, every weight piece at the same HBM address) with the
# arenas where the packer puts them.  The OLD path is kept as a named teeth
# row below and must REFUSE; it is not the default because the default is the
# image that should be loaded.
DEF_STRIPED  = ("/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27/"
                "manifest.json")
DEFECTIVE_STRIPED = ("/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/"
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
    # to bytes ONCE, as the DEFAULT of the `kv_k_base`/`kv_v_base` input
    # ports (since 2026-09-20; before that at two architecture constants the
    # port map used directly, which is what compiled the base into the
    # bitstream).  That shift is the one place a silent 16x address error
    # can be introduced, so its AMOUNT is read out of the source and checked
    # against the granule rather than assumed to be 4.
    seam = {}
    for gen, port in (("C_K_BASE_CH", "kv_k_base"),
                      ("C_V_BASE_CH", "kv_v_base")):
        m = re.search(
            r"^\s*%s\s*:\s*in\s+std_logic_vector\(C_KV_ADDR_W-1 downto 0\)"
            r"\s*:=\s*std_logic_vector\(shift_left\(\s*to_unsigned\(\s*%s\s*,"
            r"\s*C_KV_ADDR_W\s*\)\s*,\s*(\d+)\s*\)\)" % (port, gen),
            src, re.S | re.M)
        if not m:
            raise Bad(
                "rtl/llama_top.vhd: could not find the chunk-to-byte shift "
                "in the default of port %s (from %s).  attn_kv_axi's "
                "k_base/v_base are BYTE addresses (its rec_addr adds "
                "idx*REC_B with REC_B in bytes) and the generic is a CHUNK "
                "count, so a shift must exist where the generic becomes the "
                "port's default.  If it moved, this check must move with it "
                "-- a missing shift is a 16x address error that elaborates "
                "perfectly cleanly." % (port, gen))
        seam[port] = int(m.group(1))
    out["shift"] = seam

    # and the two PORTS must actually reach the instance, unmodified
    if not re.search(r"k_base\s*=>\s*kv_k_base\s*,\s*v_base\s*=>\s*kv_v_base",
                     src):
        raise Bad("rtl/llama_top.vhd: kv_k_base/kv_v_base are not the actuals "
                  "of attn_kv_axi's k_base/v_base any more.  The seam's "
                  "registers would then not be on the path the cache uses, "
                  "which is the 2026-09-20 defect again.")
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
# side 4: hw/fk33/rtl/fk33_card.vhd -- WHAT THE HARDWARE ACTUALLY GETS
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
#
# AND UNTIL 2026-09-20 THIS SIDE MADE THE SAME MISTAKE ONE LEVEL DOWN.  It read
# `hw/fk33/gen_fk33_card.py`'s SOURCE TEXT -- the `"--generic", "NAME=VALUE"`
# literals -- and printed the word "built" about the result.  The generator is
# not what is built.  `hw/fk33/rtl/fk33_card.vhd` is: it is COMMITTED, and
# `gen_pcieep.py:1274` puts it in `_CARD_ALL` -> `CARD_RTL_ADD` -> the
# `read_vhdl` list of the generated build script (:3400).  Synthesis compiles
# that file and never runs the generator.
#
# THREE SUPPORTED ROUTES MAKE THE TWO DIVERGE, and reading the source sees
# none of them:
#   1. THE ENV TRIM.  `gen_fk33_card.py`'s TRIMMABLE block rewrites the built
#      ARGS list at run time from `FK33_C_KV_BLOCK` / `FK33_A_ROWS_IF`, leaving
#      the source literals alone ON PURPOSE, so that this file's regexes keep
#      matching.  MEASURED 2026-09-20: with the artifact regenerated at
#      `FK33_C_KV_BLOCK=16`, so that `fk33_card.vhd:244` reads
#      `C_KV_BLOCK => 16,`, the old row printed
#      `gen_fk33_card C_KV_BLOCK == KVR C_KV_BLOCK  built 32 vs simulated 32`
#      and the whole check returned `40 rows, 0 refused`.
#   2. A STALE ARTIFACT.  The generator is edited and nobody regenerates.
#   3. A HAND-EDIT of the generated file, which its own banner forbids and
#      nothing prevents.
#
# Route 2 and route 3 are caught by `gen_fk33_card.py --check` (gate row
# sim:fk33card) -- but ONLY with the environment unset.  MEASURED the same day:
# in a shell exporting `FK33_C_KV_BLOCK=16`, which is the shell a trimmed build
# is run from and the only shell in which the trimmed artifact is legitimate,
# `--check` regenerates WITH the trim, matches, and prints `OK`; so
# sim:fk33card and sim:kvmap are BOTH green while the card is at 16 and
# `sim/realshape_gate.sh`'s KVR block simulates 32.  Two green rows, geometry
# diverged, and that is the 2026-09-09 defect's own shape.
#
# So side 4 now reads the ARTIFACT for every value, and the generator only as
# the thing to point the reader at.  CLAUDE.md's rule, recorded against this
# very file on 2026-09-11 ("Reading the generator instead of the artifact"),
# applied to the checker that was written in response to it.
# --------------------------------------------------------------------------
CARD_GEN = os.path.join(REPO, "hw", "fk33", "gen_fk33_card.py")
CARD_RTL = os.path.join(REPO, "hw", "fk33", "rtl", "fk33_card.vhd")

# A VHDL integer literal is not always decimal.  `A_JOB_STRIDE => 16#40000#`
# is in this very generic map, and a `(\d+)` regex reads `16` out of it: a
# silent 16x error of exactly the class side 4 exists to catch.  So the forms
# are enumerated and anything else REFUSES rather than being guessed at.
_DEC_LIT   = re.compile(r"^[+-]?\d+$")
_BASED_LIT = re.compile(r"^(\d+)#([0-9a-fA-F]+)#$")


def _as_int(name, raw):
    t = raw.replace("_", "")           # VHDL allows 1_000_000
    if _DEC_LIT.match(t):
        return int(t)
    m = _BASED_LIT.match(t)
    if m:
        return int(m.group(2), int(m.group(1)))
    raise Bad("hw/fk33/rtl/fk33_card.vhd: generic %s => %s is not an integer "
              "literal this checker knows how to read.  REFUSING rather than "
              "guessing: a decimal-only regex reads `16` out of `16#40000#`, "
              "which is a silent 16x error and is the class this side exists "
              "to catch." % (name, raw))


def card_generic_map(path=CARD_RTL):
    """Every `NAME => VALUE` of fk33_card's instantiation of fk33_llama_top.

    Values are returned RAW (as written).  The instance is pinned by name so
    that a second `generic map` elsewhere in the file cannot be read by
    mistake, and a missing one RAISES: a regex that matches nothing reports
    nothing, which is indistinguishable from a pass (CLAUDE.md, the
    silent-empty-result class).
    """
    src = open(path).read()
    m = re.search(r"entity\s+work\.fk33_llama_top\s+generic\s+map\s*\("
                  r"(.*?)\n\s*\)\s*\n\s*port\s+map", src, re.S | re.I)
    if not m:
        raise Bad("%s: no `entity work.fk33_llama_top generic map (...) port "
                  "map` could be found.  That instantiation IS the built "
                  "configuration; without it there is nothing to compare the "
                  "simulated geometry against, and this checker must refuse "
                  "rather than fall back on the generator's source text, "
                  "which is what it used to read and what the env trim "
                  "defeats." % path)
    out = {}
    for line in m.group(1).splitlines():
        mm = re.match(r"\s*(\w+)\s*=>\s*(.+?)\s*,?\s*$", line)
        if mm:
            out[mm.group(1)] = mm.group(2)
    if not out:
        raise Bad("%s: the fk33_llama_top generic map parsed to zero "
                  "generics." % path)
    return out


def _read_int_generic(path, name, gm=None):
    """An INTEGER generic of the BUILT card cell, or None if it is not set.

    None means "the card cell does not pass it", so `fk33_llama_top`'s own
    default ships -- which for C_N_ROT is itself the defect.  Separate from
    _read_bool_generic so that a boolean cannot read as absent.
    """
    gm = card_generic_map(path) if gm is None else gm
    raw = gm.get(name)
    if raw is None or raw.startswith('"') or raw in ("true", "false"):
        return None
    return _as_int(name, raw)


def _read_bool_generic(path, name, gm=None):
    """True/False for a BOOLEAN generic of the built card cell, or None."""
    gm = card_generic_map(path) if gm is None else gm
    raw = gm.get(name)
    return None if raw not in ("true", "false") else (raw == "true")


def read_card(path=CARD_RTL):
    """The INTEGER `C_*` generics the BUILD gets, from the artifact it gets."""
    gm = card_generic_map(path)
    out = {}
    for k, v in gm.items():
        if not k.startswith("C_"):
            continue
        if v.startswith('"') or v in ("true", "false"):
            continue          # C_QKN_IMAGE, C_KV_AXI, C_REAL
        out[k] = _as_int(k, v)
    return out


# THE PROVENANCE ROW.  `card_generic_map` reads the VALUES, which closes the
# trim for every generic this file compares against an authority.  It cannot
# close it for a generic with NO authority -- `A_ROWS_IF` is the other
# TRIMMABLE and `sim/realshape_gate.sh` says nothing about it -- and it cannot
# say WHY two numbers differ.  The GENSTAMP block that TRACK GENSTAMP put in
# the generated file answers both: it names every out-of-band input and its
# value, is written from the same list the generator trims from, and is
# deterministic, so an unstamped or differently-stamped artifact is visible.
#
# SCOPE, stated rather than assumed: A_ROWS_IF is not a KV generic, and nor is
# HOST_WINDOW, whose row three screens down carries the same argument -- same
# failure mode, same file, nowhere better for it.  An artifact built under ANY
# trim is not the configuration `sim/realshape_gate.sh` describes, so every
# "built X vs simulated X" row in this file is making a claim about a
# configuration nobody reviewed.  Saying so is this row's whole job.
_STAMP_RE = re.compile(r"^--\s+env\s+(FK33_\w+)\s*=\s*(.+?)\s*$", re.M)


def card_stamp_inputs(path=CARD_RTL):
    """[(name, value-or-None)] from the artifact's GENSTAMP block.

    None is the generator's `(unset)`, i.e. its own default was taken.  An
    EMPTY list means the file carries no stamp at all, which is itself
    reportable -- it is either pre-2026-09-20 or hand-made.
    """
    head = open(path).read().split("\nlibrary ", 1)[0]
    return [(n, None if v == "(unset)" else v)
            for n, v in _STAMP_RE.findall(head)]


def kv_extent_rows(row, label, doc, K, V, MP, PERTOK):
    """The rows that would have caught 2026-09-20.  `doc` is the WHOLE
    manifest (files and hbm), K and V the BYTE bases the host programs, MP
    the card's C_MAXPOS.  Every row names the manifest it was run against,
    because the point is that there are two of them."""
    h = doc["hbm"]
    half = MP * (PERTOK // 2)
    lo, hi = K, V + half            # [lo, hi), the K region then the V region
    row("%s: V == K + C_MAXPOS*(kv_bytes_per_token/2)" % label,
        V == K + half,
        "K %d, V %d, K + %d*%d = %d" % (K, V, MP, PERTOK // 2, K + half))
    row("%s: KV extent starts at hbm.kv_base" % label,
        K == int(h["kv_base"]),
        "K %d vs hbm.kv_base %d (delta %d)" % (K, h["kv_base"],
                                               K - int(h["kv_base"])))
    row("%s: KV extent inside hbm.size" % label, hi <= int(h["size"]),
        "[%d, %d) against size %d (%d bytes past the end)"
        % (lo, hi, h["size"], max(0, hi - int(h["size"]))))
    # every piece of every file: striped entries carry `pieces`, flat entries
    # carry hbm_offset/nbytes at the top level.  Both are ABSOLUTE HBM byte
    # addresses (the maximum end equals hbm.weights_end in both manifests).
    hits = []
    for f in doc["files"]:
        if f.get("pieces"):
            for pc in f["pieces"]:
                a, n = int(pc["hbm_offset"]), int(pc["nbytes"])
                if a < hi and lo < a + n:
                    hits.append((a, "%s lane %s seg %s [%d, %d)"
                                 % (f["file"], pc.get("lane"),
                                    pc.get("segment"), a, a + n)))
        else:
            a, n = int(f["hbm_offset"]), int(f["nbytes"])
            if a < hi and lo < a + n:
                hits.append((a, "%s [%d, %d)" % (f["file"], a, a + n)))
    hits.sort()
    row("%s: KV extent intersects no weight piece" % label, not hits,
        "%d piece(s) hit; first (lowest address): %s"
        % (len(hits), hits[0][1]) if hits else
        "0 of the pieces of %d files intersect [%d, %d)"
        % (len(doc["files"]), lo, hi))
    for name, bkey, nkey in (("gdn_state", "gdn_state_base", "gdn_state_bytes"),
                             ("gdn_const", "gdn_const_base", "gdn_const_bytes"),
                             ("desc_arena", "desc_arena_base",
                              "desc_arena_bytes")):
        if bkey not in h:
            row("%s: KV extent clear of %s" % (label, name), None,
                "manifest declares no %s" % bkey)
            continue
        a, n = int(h[bkey]), int(h[nkey])
        clear = not (a < hi and lo < a + n)
        row("%s: KV extent clear of %s" % (label, name), clear,
            "%s [%d, %d) against KV [%d, %d)" % (name, a, a + n, lo, hi))


def check(manifest_path=DEF_MANIFEST, require_manifest=True, out=sys.stdout,
          rtl_over=None, gate_over=None, sz_over=None, mani_over=None,
          striped_path=DEF_STRIPED, kv_over=None, extent_rows=True,
          residency_rows=True, res_over=None, card_path=CARD_RTL,
          card_rows=True):
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
    flat_doc = striped_doc = None
    if manifest_path and os.path.exists(manifest_path):
        flat_doc = json.load(open(manifest_path))
        mani = flat_doc["hbm"]
    if mani_over is not None:
        mani = dict(mani or {})
        mani.update(mani_over)
    if striped_path and os.path.exists(striped_path):
        striped_doc = json.load(open(striped_path))

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

    # ---- BOTH IMAGES AGAINST THE CARD'S GEOMETRY (2026-09-20) -------------
    # K and V here are what the HOST PROGRAMS (server/pl_backend.c: K =
    # hbm.kv_base, V = K + KV_MAXPOS * kv_bytes_per_token/2, KV_MAXPOS read
    # from the seam), not the default generics.  `kv_over` substitutes a
    # different pair -- the teeth row feeds the flat manifest's compiled pair
    # to the striped image, which is exactly the defect.  `extent_rows=False`
    # is the attribution control: the same inputs with these rows off.
    if extent_rows:
        for label, doc in (("flat", flat_doc), ("striped", striped_doc)):
            if doc is None:
                row("%s manifest: extent rows" % label, None,
                    "no manifest at %s; the rows that check the card's "
                    "geometry against this image DID NOT RUN"
                    % (manifest_path if label == "flat" else striped_path))
                continue
            hk = int(doc["hbm"]["kv_base"])
            mp = MP
            if kv_over and label in kv_over:
                hk, mp = kv_over[label]
            kv_extent_rows(row, label + " manifest", doc,
                           hk, hk + mp * (PERTOK // 2), mp, PERTOK)

    # ---- THE PSEUDO-CHANNEL THE ARENAS DECODE TO (2026-09-20, ARENAPLACE) --
    #
    # Every row above is about BYTES: does the KV region fit, does it overlap
    # a weight piece, does it run into gdn_const.  The 2026-09-20 arena defect
    # violates NONE of them.  `hbm_map.write_arenas()` pulled the GDN state
    # and the bottom of the KV cache down into segment 26 -- a pseudo-channel
    # six weight lanes read -- and they landed in that segment's TAIL, above
    # the highest lane arena, overlapping nothing.  Every check in this file
    # passed it, which is the attribution control below.
    #
    # The rule is `hbm_map.stripe_residency_fails()`, imported rather than
    # restated so this file and the map cannot disagree about it, and it is
    # INERT on a flat manifest by construction (no `lane_stripe` block, no
    # lane segments, nothing to be on).  `res_over` substitutes `hbm` fields
    # for the teeth.
    if residency_rows:
        import hbm_map as HM
        for label, doc in (("flat", flat_doc), ("striped", striped_doc)):
            if doc is None:
                row("%s manifest: arena pseudo-channel residency" % label,
                    None, "no manifest; the rule DID NOT RUN")
                continue
            d = doc
            if res_over and label in res_over:
                d = dict(doc)
                d["hbm"] = dict(doc["hbm"])
                d["hbm"].update(res_over[label])
            lanes = HM.stripe_lane_segments(d)
            bad = HM.stripe_residency_fails(d)
            if not lanes:
                detail = ("this manifest has no hbm.lane_stripe block, so no "
                          "pseudo-channel is a weight lane's and the rule is "
                          "vacuous here")
            else:
                hb = d["hbm"]
                detail = ("%d lane segment(s); gdn_state at %#x is segment "
                          "%d, kv_base at %#x is segment %d%s"
                          % (len(lanes), int(hb["gdn_state_base"]),
                             int(hb["gdn_state_base"]) // HM.SEGMENT_BYTES,
                             int(hb["kv_base"]),
                             int(hb["kv_base"]) // HM.SEGMENT_BYTES,
                             "" if not bad else
                             "  <-- " + bad[0].split(".  ")[0]))
            row("%s manifest: GDN state and KV arena clear of every weight "
                "lane's pseudo-channel" % label, not bad, detail)

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
    # `card_rows=False` is the ATTRIBUTION CONTROL for this whole side: the
    # same inputs with side 4 off.  A mutant that the control also refuses was
    # caught by some older row and side 4 cannot claim it.
    card = stamp = None
    if card_rows:
        try:
            card = read_card(card_path)
        except OSError as e:
            row("hw/fk33/rtl/fk33_card.vhd is readable", False, str(e))
            card = None
        # PROVENANCE FIRST -- it is what makes the VALUES below meaningful.
        try:
            stamp = card_stamp_inputs(card_path)
        except OSError as e:
            stamp = None
            row("hw/fk33/rtl/fk33_card.vhd carries a GENSTAMP", False, str(e))
    if stamp is not None:
        trims = [(n, v) for n, v in stamp if v is not None]
        if not stamp:
            row("the built card was generated with no trim in force", False,
                "hw/fk33/rtl/fk33_card.vhd carries no GENSTAMP `env FK33_*` "
                "lines at all, so what produced it is not recoverable from "
                "the file.  Regenerate with hw/fk33/gen_fk33_card.py.")
        elif trims:
            row("the built card was generated with no trim in force", False,
                "%s -- the artifact is NOT the default geometry, so every "
                "'built X vs simulated X' row below compares the card against "
                "a KVR block that does not describe it.  Move "
                "sim/realshape_gate.sh's KVR to match, or drop the trim."
                % ", ".join("%s=%s" % (n, v) for n, v in trims))
        else:
            row("the built card was generated with no trim in force", True,
                "%d stamped input(s), all (unset): %s"
                % (len(stamp), ", ".join(n for n, _ in stamp)))
    if card is not None:
        # HOST_WINDOW is not a KV generic, but it is the SAME FAILURE MODE in
        # the SAME FILE and there is nowhere better for it.  MEASURED
        # 2026-09-10: it defaults to TRUE (simulation), `fk33_llama_top`
        # re-declares it TRUE, and gen_fk33_card.py did not override it -- so
        # every card build asked Vivado to optimise region_mem as 2,752,512
        # REGISTERS instead of BRAM, because a combinational full-range read
        # port cannot be a BRAM.  rtl/region_mem.vhd says so in the comment
        # above the generic and records FALSE as the card configuration.
        # Ten builds and ~40 hours were spent against that.
        hw = _read_bool_generic(card_path, "HOST_WINDOW")
        row("built card sets HOST_WINDOW=false", hw is False,
            "got %r; the card must be false -- region_mem's combinational host "
            "read port forces 2,752,512 registers when true, and nothing on "
            "the board drives that port" % (hw,))

    if card is not None:
        for name in ("C_KV_BLOCK", "C_K_BASE_CH", "C_V_BASE_CH",
                     "C_KV_ADDR_W", "C_MAXPOS", "C_CTXLEN"):
            want = gate.get(name)
            got  = card.get(name)
            if want is None:
                row("built card %s has an authority" % name, False,
                    "sim/realshape_gate.sh's KVR block does not set %s, so "
                    "there is nothing to compare the build against" % name)
            elif got is None:
                row("built card sets %s" % name, False,
                    "hw/fk33/rtl/fk33_card.vhd's fk33_llama_top instance "
                    "passes no %s, so the card cell is built with "
                    "fk33_llama_top's DEFAULT and not the 9B value %d.  This "
                    "is the 2026-09-09 defect." % (name, want))
            else:
                row("built card %s == KVR %s" % (name, name), got == want,
                    "built %d vs simulated %d%s"
                    % (got, want, "" if got == want else "  <-- DIVERGED"))

    # ----------------------------------------------------------------------
    # C_N_ROT AGAINST THE GENERATED RoPE TABLE.  Added 2026-09-11.
    #
    # Elaboration CANNOT catch this one, which is why it needs a static row.
    # attn_block asserts only `N_ROT mod 2 = 0 and N_ROT <= HEAD_DIM`, so
    # llama_top's simulation-scaled default of 8 is perfectly legal at
    # HEAD_DIM 256: it raises nothing, indexes 4 of the table's 32 entries,
    # and rotates the wrong number of dimensions. A build that succeeds and
    # computes garbage -- the same class as the KV-geometry defect this whole
    # side exists for, and the same trap as C_KV_BLOCK's default of 4.
    #
    # The table is GENERATED, so the correct value is not a matter of opinion:
    # tools/gen_imrope_pkg.py emits NPAIR = N_ROT/2 entries, and rtl/
    # imrope_pkg.vhd records that as IMROPE_NPAIR. So the card's C_N_ROT must
    # be exactly 2 * IMROPE_NPAIR, and that is what is asserted here rather
    # than the literal 64, so regenerating the table at a different width
    # moves the requirement with it.
    IMROPE = os.path.join(REPO, "rtl", "imrope_pkg.vhd")
    m = re.search(r"constant\s+IMROPE_NPAIR\s*:\s*integer\s*:=\s*(\d+)",
                  open(IMROPE).read())
    # This row reads the same artifact, so it belongs to side 4 and must go
    # dark under the attribution control too -- otherwise the control refuses
    # for a reason that has nothing to do with the mutant and every mutant
    # scores as "caught by something older".
    try:
        card_nrot = (_read_int_generic(card_path, "C_N_ROT")
                     if card_rows else None)
    except OSError:
        # read_card() has already put a refusing row in for the same file;
        # this one must not crash out of the check and lose every row.
        card_nrot, card_rows = None, False
    if not card_rows:
        pass
    elif m is None:
        rows.append(("card C_N_ROT == 2*IMROPE_NPAIR", False,
                     "could not read IMROPE_NPAIR from %s" % IMROPE))
    elif card_nrot is None:
        rows.append(("card C_N_ROT == 2*IMROPE_NPAIR", False,
                     "hw/fk33/rtl/fk33_card.vhd passes no C_N_ROT, so "
                     "fk33_llama_top's SIMULATION default of 8 would ship "
                     "(table wants %d)" % (2 * int(m.group(1)))))
    else:
        want = 2 * int(m.group(1))
        rows.append(("card C_N_ROT == 2*IMROPE_NPAIR", card_nrot == want,
                     "built %d vs table %d (IMROPE_NPAIR=%s); at the wrong "
                     "value RoPE rotates the wrong number of dimensions and "
                     "NOTHING raises" % (card_nrot, want, m.group(1))))

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
# --------------------------------------------------------------------------
# SIDE-4 MUTANTS ARE REAL FILES, NOT SUBSTITUTED DICTS.
#
# CLAUDE.md's recorded `seam_tieoff_teeth()` failure was a check and a mutant
# built from the SAME misconception, so all four rows agreed with each other
# while the thing they guarded was dead.  The misconception under test here is
# "the built configuration is what gen_fk33_card.py's source text says".  A
# mutant injected as a dict bypasses the reader entirely and therefore cannot
# distinguish reading the generator from reading the artifact -- it would pass
# identically against the OLD code.  So every side-4 mutant below WRITES A
# `fk33_card.vhd` and hands over its path, and the real parser reads it.
#
# MEASURED 2026-09-20, the equivalence that makes `card_mutant` honest: a
# `fk33_card.vhd` really produced by `FK33_C_KV_BLOCK=16 python3
# hw/fk33/gen_fk33_card.py` differs from the committed one in exactly the
# three lines the `TRIM16` mutant edits -- the reproduce line, the `env` line
# and `C_KV_BLOCK => 16,` -- plus the two `..._IMAGE` paths, which differ
# because that run was made in a scratch checkout and not because of the trim
# (they are the one legitimately location-dependent thing in this file, and
# `gen_fk33_card.py --check` canonicalises them for the same reason).
# --------------------------------------------------------------------------
def card_mutant(tmpdir, tag, subs, src=CARD_RTL):
    """Write a mutated copy of the card artifact and return its path.

    `subs` is a list of (old, new) literal substitutions, each of which MUST
    hit exactly once -- a substitution that matches nothing produces a file
    identical to the control, which scores as "the check did not bite" and is
    indistinguishable from a real hole.
    """
    text = open(src).read()
    for old, new in subs:
        n = text.count(old)
        if n != 1:
            raise Bad("card_mutant(%s): %r appears %d times in %s, want 1"
                      % (tag, old, n, src))
        text = text.replace(old, new)
    dst = os.path.join(tmpdir, "fk33_card.%s.vhd" % tag)
    open(dst, "w").write(text)
    return dst


# The two stamp lines the generator writes for a trim, verbatim, so a mutant
# that claims a trim is shaped exactly like a real one.
_STAMP_UNSET = "--     env  FK33_C_KV_BLOCK = (unset)"
_REPRO_PLAIN = "--     python3 hw/fk33/gen_fk33_card.py"


def teeth(manifest_path, striped_path=DEF_STRIPED):
    import io
    # THE 2026-09-20 DEFECT AS A MUTANT: the striped image loaded, the card
    # at C_MAXPOS 131072 with the FLAT manifest's pair compiled in, i.e. K =
    # 282672640*16.  The row must refuse NAMING the first weight piece the
    # pair lands on.  Its attribution control is the same mutant with the
    # extent rows disabled; it must be ACCEPTED, which is the measurement
    # that the older rows could not see this.
    flat_k = 282672640 * 16
    defect = dict(kv_over={"striped": (flat_k, 131072)})
    cases = [
        ("control", {}, False),
        ("striped_image_with_the_compiled_flat_pair_at_131072", defect, True),
        ("  attribution control: same mutant, extent rows OFF",
         dict(defect, extent_rows=False), False),
        ("striped_image, K one page below hbm.kv_base",
         dict(kv_over={"striped": (7204880384 - 4096, 65536)}), True),
        # kv_extents[0].tokens is 233237 = floor(free/17408), so 233237
        # fits by construction and ONE more token puts the V region's last
        # 17,408 bytes into gdn_const.
        ("flat_image, C_MAXPOS 233238 (one past kv_extents.tokens, hits gdn_const)",
         dict(kv_over={"flat": (4522762240, 233238)}), True),
        ("striped_image, C_MAXPOS 131072 at the right base (does not fit)",
         dict(kv_over={"striped": (7204880384, 131072)}), True),
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
        ("maxpos_doubled_back_to_131072", dict(gate_over={"C_MAXPOS": 131072}),
         True),
        ("addr_w_one_short", dict(gate_over={"C_KV_ADDR_W": 32}), True),
        ("kv_block_illegal", dict(gate_over={"C_KV_BLOCK": 3}), True),
        ("the seam shifts by 3", dict(rtl_over={"shift": {"kv_k_base": 3,
                                                          "kv_v_base": 4}}),
         True),
        ("the seam shifts by 5", dict(rtl_over={"shift": {"kv_k_base": 4,
                                                          "kv_v_base": 5}}),
         True),
        ("the seam does not shift", dict(rtl_over={"shift": {"kv_k_base": 0,
                                                             "kv_v_base": 0}}),
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

        # ---- THE 2026-09-20 ARENA-PLACEMENT DEFECT (TRACK ARENAPLACE) ----
        # The first row is not a synthetic mutant: it is the image that was
        # loaded on the card, at its real path, as it stands on disk.  Its
        # attribution control is the SAME image with only the residency rows
        # off, and it must be ACCEPTED -- that is the measurement that every
        # pre-existing row in this file was blind to the placement.
        ("THE SHIPPED striped image .../noembd-striped as it stands today",
         dict(striped_path=DEFECTIVE_STRIPED), True),
        ("  attribution control: same image, residency rows OFF",
         dict(striped_path=DEFECTIVE_STRIPED, residency_rows=False), False),
        # 0x1b000_0000 is segment 27, the first segment above the highest
        # weight lane.  One byte below it the state begins in segment 26 and
        # the rule must bite; exactly on it the rule must be silent.  These
        # two rows are the boundary itself, so a rule that was off by one
        # segment in either direction cannot pass both.
        ("gdn_state ONE BYTE BELOW the segment boundary (0x1afffffff)",
         dict(res_over={"striped": {"gdn_state_base": 0x1b000_0000 - 1}}),
         True),
        ("gdn_state EXACTLY ON the segment boundary (0x1b0000000)",
         dict(res_over={"striped": {"gdn_state_base": 0x1b000_0000}}), False),
        ("gdn_state one PAGE below the boundary (0x1affff000)",
         dict(res_over={"striped": {"gdn_state_base": 0x1b000_0000 - 4096}}),
         True),
        ("kv_base alone dragged back into segment 26, gdn_state left correct",
         dict(res_over={"striped": {"kv_base": 0x1ad71_c000}}), True),
        # DOES NOT BITE, KEPT AND NAMED.  A base one byte ABOVE the boundary
        # is inside reserved segment 27, so no lane shares its pseudo-channel
        # and P7 is silent -- correctly, because the contention is a property
        # of WHICH pseudo-channel the bytes decode to and not of where in it
        # they start.  The guard that does hold the alignment is that
        # `pack_model_fk33.stripe_context_tokens()` is the only producer of
        # this base and returns a segment multiple, plus hbm_map's own 4 KB
        # region-alignment rule, which is NOT this row and is measured under
        # `hbm_map` in the ARENAPLACE teeth table.
        ("gdn_state ONE BYTE ABOVE the boundary -- DOES NOT BITE, by design",
         dict(res_over={"striped": {"gdn_state_base": 0x1b000_0000 + 1}}),
         False),
    ]

    # ---- SIDE 4: THE BUILT ARTIFACT.  Added 2026-09-20 by TRACK KVGEOM. ----
    # Until today side 4 had NO teeth row at all: every mutant above reaches
    # the gate, the RTL, the shape or a manifest, and not one of them touched
    # the card.  The side added for the 2026-09-09 "built with toy defaults"
    # defect had never been shown to refuse anything.
    import tempfile
    import shutil
    tmpd = tempfile.mkdtemp(prefix="kvmap_teeth_")
    if True:
        M = lambda tag, subs: card_mutant(tmpd, tag, subs)

        TRIM16 = [(_REPRO_PLAIN,
                   "--     FK33_C_KV_BLOCK=16 python3 "
                   "hw/fk33/gen_fk33_card.py"),
                  (_STAMP_UNSET, "--     env  FK33_C_KV_BLOCK = 16"),
                  ("C_KV_BLOCK               => 32,",
                   "C_KV_BLOCK               => 16,")]

        cases += [
            # THE TRACK'S OWN DEFECT, as the generator really emits it.
            ("card: FK33_C_KV_BLOCK=16 trim, exactly as the generator emits it",
             dict(card_path=M("trim16", TRIM16)), True),
            ("  attribution control: same artifact, side-4 rows OFF",
             dict(card_path=M("trim16b", TRIM16), card_rows=False), False),
            # The two halves separately, so neither row rides on the other.
            ("card: the VALUE trimmed to 16, stamp still says (unset)",
             dict(card_path=M("val16", TRIM16[2:])), True),
            ("card: the STAMP says 16, the value still 32 (a stale stamp)",
             dict(card_path=M("stamp16", TRIM16[:2])), True),
            # A_ROWS_IF is the OTHER TRIMMABLE and has NO authority in
            # sim/realshape_gate.sh, so only the provenance row can see it.
            ("card: FK33_A_ROWS_IF=24 trim (only the stamp row can see it)",
             dict(card_path=M("rows24", [
                 (_REPRO_PLAIN, "--     FK33_A_ROWS_IF=24 python3 "
                                "hw/fk33/gen_fk33_card.py"),
                 ("--     env  FK33_A_ROWS_IF  = (unset)",
                  "--     env  FK33_A_ROWS_IF  = 24"),
                 ("A_ROWS_IF                => 48,",
                  "A_ROWS_IF                => 24,")])), True),
            # DOES NOT BITE, KEPT AND NAMED.  The same A_ROWS_IF value change
            # with an HONEST-looking (unset) stamp is invisible: nothing in
            # this tree states what A_ROWS_IF must be, so there is no
            # authority to compare it against.  This row measures the
            # resolution floor of side 4 and must not be "fixed" by inventing
            # a bound -- gen_fk33_card.py's LEGAL table deliberately records
            # none for A_ROWS_IF for the same reason.
            ("card: A_ROWS_IF 48 -> 24 with a clean stamp -- DOES NOT BITE",
             dict(card_path=M("rows24q", [("A_ROWS_IF                => 48,",
                                           "A_ROWS_IF                => 24,")])),
             False),
            # THE 2026-09-09 DEFECT ITSELF: llama_top's simulation defaults.
            ("card: C_MAXPOS => 4, llama_top's sim default (2026-09-09)",
             dict(card_path=M("mp4", [("C_MAXPOS                 => 65536,",
                                       "C_MAXPOS                 => 4,")])),
             True),
            ("card: C_K_BASE_CH one chunk high",
             dict(card_path=M("kb1", [("C_K_BASE_CH              => 282672640,",
                                       "C_K_BASE_CH              => 282672641,")])),
             True),
            ("card: the C_N_ROT generic deleted (sim default 8 ships)",
             dict(card_path=M("nonrot", [("      C_N_ROT                  => 64,\n", "")])),
             True),
            ("card: HOST_WINDOW => true (the 2026-09-10 register blow-up)",
             dict(card_path=M("hw", [("HOST_WINDOW              => false,",
                                      "HOST_WINDOW              => true,")])),
             True),
            # THE BASED-LITERAL TRAP.  `A_JOB_STRIDE => 16#40000#` is already
            # in this generic map; a decimal-only regex reads `16` out of it.
            # The first row must be ACCEPTED (16#10000# IS 65536) and is the
            # control that the parser reads the form rather than skipping it;
            # the second must REFUSE, which is what proves it read the VALUE
            # and did not merely tolerate the syntax.
            ("card: C_MAXPOS => 16#10000#, the same 65536 -- must be ACCEPTED",
             dict(card_path=M("hex_ok", [("C_MAXPOS                 => 65536,",
                                          "C_MAXPOS                 => 16#10000#,")])),
             False),
            ("card: C_MAXPOS => 16#10001#, 65537 in hex",
             dict(card_path=M("hex_bad", [("C_MAXPOS                 => 65536,",
                                           "C_MAXPOS                 => 16#10001#,")])),
             True),
            # The reader must REFUSE an unreadable artifact, never fall back.
            ("card: the whole generic map replaced by an expression",
             dict(card_path=M("expr", [("C_MAXPOS                 => 65536,",
                                        "C_MAXPOS                 => 2**16,")])),
             True),
            ("card: no `entity work.fk33_llama_top generic map` at all",
             dict(card_path=M("nomap", [("entity work.fk33_llama_top",
                                         "entity work.fk33_llama_top_RENAMED")])),
             True),
            ("card: the artifact does not exist",
             dict(card_path=os.path.join(tmpd, "no_such_card.vhd")), True),
        ]
    npass = nmiss = 0
    print("==== teeth for tools/check_kv_map.py ====")
    print("     side-4 mutants are real files under %s" % tmpd)
    for name, kw, want_refuse in cases:
        buf = io.StringIO()
        # a case may name its OWN striped image; the 2026-09-20 row does,
        # because the defect it measures lives at a path that is no longer
        # the default.
        kw = dict(kw)
        try:
            rc = check(manifest_path, require_manifest=True, out=buf,
                       striped_path=kw.pop("striped_path", striped_path), **kw)
        except Bad as e:
            # main() turns a Bad into rc 2, so teeth must score it the same
            # way or a mutant that breaks the READER would look like a hole.
            rc = 2
            buf.write("  REFUSED (Bad) %s\n" % e)
        refused = rc != 0
        if refused == want_refuse:
            npass += 1
            verdict = "REFUSED" if refused else "accepted"
        else:
            nmiss += 1
            verdict = ("DID NOT REFUSE -- THIS IS A HOLE"
                       if want_refuse else "REFUSED THE CONTROL")
        # EVERY refused row, not the first: the 2026-09-20 defect row must
        # be seen to NAME the weight piece it lands on, and that is not the
        # first row that refuses it.
        lines = [ln.strip() for ln in buf.getvalue().splitlines()
                 if ln.strip().startswith("REFUSED")]
        print("  %-66s %s" % (name, verdict))
        for line in lines[:6]:
            print("        %s" % line[:190])
    print("---- %d of %d teeth rows behaved as intended ----"
          % (npass, npass + nmiss))
    shutil.rmtree(tmpd, ignore_errors=True)
    return 0 if nmiss == 0 else 1


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=DEF_MANIFEST)
    ap.add_argument("--striped-manifest", default=DEF_STRIPED,
                    help="the lane-striped image's manifest; its KV extent "
                         "is checked against the card's geometry too")
    ap.add_argument("--no-manifest", action="store_true",
                    help="run the in-repo rows only, and say so; still "
                         "refuses on any in-repo mismatch")
    ap.add_argument("--teeth", action="store_true")
    a = ap.parse_args(argv)
    if a.teeth:
        return teeth(a.manifest, a.striped_manifest)
    try:
        return check(a.manifest, require_manifest=not a.no_manifest,
                     striped_path=a.striped_manifest)
    except Bad as e:
        sys.stderr.write("check_kv_map: REFUSING -- %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
