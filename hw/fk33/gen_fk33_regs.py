#!/usr/bin/env python3
"""Emit the FK33 host/device register map as a C header, from ONE source.

WHY THIS EXISTS.  The map was defined twice: as Python constants in
gen_pcieep.py, which configures the block design and therefore decides what the
hardware actually does, and again as #define lines in host/fk33_bringup.c with
a comment reading "Must match hw/fk33/gen_pcieep.py".  A comment is not a
mechanism.  The two copies agreed only for as long as someone remembered.

That was survivable inside one repository and is not survivable across two: the
host runtime now lives in its own repo, so a silent divergence would put a
correct-looking host program against a differently-mapped bitstream, and the
symptom would be reads returning plausible values from the wrong peripheral.

So gen_pcieep.py stays the single source and this emits the header from it.
Run with --check to verify the checked-in header is in step; that is the same
pattern tools/gen_arith.py already uses in this project, and it exists because
a generated file that nobody verifies drifts exactly as fast as a duplicated
one.  Note what happened there: someone hand-added a real fix to the GENERATED
file and every build silently deleted it.  Do not edit fk33_regs.h.
"""
import argparse
import importlib.util
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
TARGET = HERE / "host" / "fk33_regs.h"
DESC_PKG = HERE.parent.parent / "rtl" / "matvec_int4_desc_pkg.vhd"
DESC_AXI = HERE.parent.parent / "rtl" / "matvec_int4_desc_axi.vhd"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_source():
    return _load("gen_pcieep", HERE / "gen_pcieep.py")


def load_engine():
    """hw/fk33/gen_fk33_engine.py GENERATES rtl/fk33_engine.vhd, so it is the
    source for the engine's synthesis geometry and for the activation writer's
    ENG1 magic in exactly the way gen_pcieep.py is the source for the base
    addresses.  Importing it here is what stops the geometry the host CHECKS
    from becoming a fourth copy of the geometry the fabric WAS BUILT WITH."""
    return _load("gen_fk33_engine", HERE / "gen_fk33_engine.py")


def scrape_desc_pkg():
    """MV4I_MAGIC and the error-code space out of rtl/matvec_int4_desc_pkg.vhd.

    That package is the file both the gateware and the descriptor generator
    compute from, so it is the source here too.  A miss RAISES rather than
    defaulting: an error code the host names wrongly is worse than one it
    cannot name at all, because the first produces a confident wrong diagnosis
    on a card that refused a descriptor for a reason nobody then looks for."""
    txt = DESC_PKG.read_text()
    m = re.search(r'constant\s+MV4I_MAGIC\s*:.*?:=\s*x"([0-9A-Fa-f]{8})"', txt)
    if not m:
        raise SystemExit("gen_fk33_regs: MV4I_MAGIC not found in %s" % DESC_PKG)
    magic = int(m.group(1), 16)
    codes = re.findall(r'constant\s+(EC_[A-Z]+)\s*:\s*std_logic_vector\(3 downto 0\)'
                       r'\s*:=\s*x"([0-9A-Fa-f])"', txt)
    if len(codes) < 10:
        raise SystemExit("gen_fk33_regs: expected the full EC_* space in %s, "
                         "found %d" % (DESC_PKG, len(codes)))
    return magic, [(n, int(v, 16)) for n, v in codes]


# The engine's own AXI-Lite map, byte offset -> (name, access).  TRANSCRIBED
# from rtl/matvec_int4_desc_axi.vhd's `wrp` and `rdp` decodes, which switch on
# `reg = addr[7:2]`, and CHECKED against that file's header table by
# check_reg_table() below.
#
# Read what that check does and does not do.  It compares this transcription
# against the RTL's COMMENT, so two transcriptions of the same decode agreeing
# is all it proves; the decode itself was read by hand (writes decode 0, 1, 2,
# 9; reads decode 0, 1, 3..8, 10..15, and CTRL/Y_IDX are write-only in both).
# The check that has real teeth is on the card and is in fk33_run_job.py: ID,
# ADDR_CAP, CAPS and DESC_WORDS are four constants at four different offsets,
# and all four reading their expected values cannot happen if this table is
# shifted.
ENG_REGS = [
    (0x00, "DESC_PTR_LO", "RW"),
    (0x04, "DESC_PTR_HI", "RW"),
    (0x08, "CTRL",        "W"),
    (0x0C, "STATUS",      "R"),
    (0x10, "ERR_INFO",    "R"),
    (0x14, "ID",          "R"),
    (0x18, "ADDR_CAP",    "R"),
    (0x1C, "CAPS",        "R"),
    (0x20, "DESC_WORDS",  "R"),
    (0x24, "Y_IDX",       "W"),
    (0x28, "Y_LO",        "R"),
    (0x2C, "Y_HI",        "R"),
    (0x30, "Y_EXP",       "R"),
    (0x34, "CYCLES",      "R"),
    (0x38, "BEATS",       "R"),
    (0x3C, "STARVED",     "R"),
]

# The activation writer, rtl/fk33_engine.vhd (generated).  Its decode is on
# addr[11:2] and is written out in gen_fk33_engine.py's BODY docstring.
ENGX_REGS = [
    (0x00, "X_ADDR",  "RW"),
    (0x04, "X_DATA",  "W"),
    (0x08, "STAT",    "R"),
    (0x0C, "ID",      "R"),
]


def check_reg_table():
    """Require rtl/matvec_int4_desc_axi.vhd's header table to name the same
    sixteen registers at the same offsets, in the same order."""
    txt = DESC_AXI.read_text()
    found = re.findall(r'^--\s+(0x[0-9A-F]{2})\s+([A-Z_0-9]+)\s+(RW|R|W)\s',
                       txt, re.M)
    want = [("0x%02X" % o, n, a) for o, n, a in ENG_REGS]
    got = [(o, n, a) for o, n, a in found]
    if got != want:
        return ("the register table in %s does not match ENG_REGS in this "
                "generator.\n  RTL header: %r\n  generator:  %r"
                % (DESC_AXI, got, want))
    return None


def size_bytes(v):
    """gen_pcieep spells sizes as Vivado strings: '8K', '64K'."""
    if isinstance(v, int):
        return v
    s = str(v).strip().upper()
    if s.endswith("K"):
        return int(s[:-1]) * 1024
    if s.endswith("M"):
        return int(s[:-1]) * 1024 * 1024
    return int(s, 0)


def render(g):
    return f'''/* GENERATED by hw/fk33/gen_fk33_regs.py from hw/fk33/gen_pcieep.py.
 *
 * DO NOT EDIT.  gen_pcieep.py configures the block design, so it decides what
 * the hardware does; this file only reports it.  An edit here changes what the
 * host believes and not what the card implements, which is the one failure
 * mode this header exists to prevent.
 *
 * Verify with:  python3 hw/fk33/gen_fk33_regs.py --check
 */
#ifndef FK33_REGS_H
#define FK33_REGS_H

#include <stdint.h>

/* ---- AXI-Lite BAR, 128 KB, /dev/xdma0_user ----------------------------- */

/* Read-only identity, axi_gpio with both channels all-inputs.  A correct read
 * is not something a merely-loaded driver can fake: 0xFFFFFFFF means the BAR
 * is mapped with nothing answering, and 0x00000000 means the fabric is in
 * reset, so both of the plausible wrong answers are distinguishable. */
#define FK33_ID_BASE        0x{g.ID_BASE:08X}u
#define FK33_ID_MAGIC_OFF   (FK33_ID_BASE + 0x0u)
#define FK33_ID_BUILD_OFF   (FK33_ID_BASE + 0x8u)
#define FK33_ID_MAGIC       0x{g.ID_MAGIC:08X}u   /* "FK33" in ASCII */
#define FK33_ID_BUILD       0x{g.ID_BUILD:08X}u   /* yyyymmdd */

/* Read/write scratch BRAM.  The only thing in the design that proves MMIO
 * WRITES land without driving a real board pin. */
#define FK33_SCRATCH_BASE   0x{g.SCRATCH_BASE:08X}u
#define FK33_SCRATCH_SIZE   0x{size_bytes(g.SCRATCH_SIZE):X}u

/* ---- DMA master space, /dev/xdma0_h2c_0 and _c2h_0 --------------------- */
/* The file offset IS the AXI address, which is the whole reason XDMA was
 * chosen over QDMA. */

/* Deliberately ABOVE the 8 GB of HBM, so a DMA fault can never be confused
 * with an HBM fault and an off-by-one in a host offset lands on nothing
 * rather than silently in memory. */
#define FK33_DMABRAM_BASE   0x{g.DMABRAM_BASE:X}ull
#define FK33_DMABRAM_SIZE   0x{size_bytes(g.DMABRAM_SIZE):X}ull
#define FK33_HBM_TOP        0x{g.DMABRAM_BASE:X}ull

/* ---- Thermal protection ------------------------------------------------ */
/* Five status words plus one control word, produced by rtl/fk33_thermal.vhd on
 * the free-running aux clock and resynchronised into the AXI-Lite clock domain
 * by the module itself.  The SAME five words are also readable over the
 * jtag_aux master with the PCIe link DOWN, at a different address space -- so a
 * card that has halted and dropped off the bus can still be asked why.
 *
 * THERM_STATUS bit 31 is a constant 1.  A bitstream WITHOUT the thermal guard
 * reads 0 there, so "is this card protected" is one read and not a guess. */
#define FK33_THERM_BASE     0x{g.THERM_BASE:08X}u
#define FK33_THERM_STATUS   (FK33_THERM_BASE  + 0x0u)
#define FK33_THERM_TEMPS    (FK33_THERM_BASE  + 0x8u)
#define FK33_THERMP_BASE    0x{g.THERMP_BASE:08X}u
#define FK33_THERM_PEAK     (FK33_THERMP_BASE + 0x0u)
#define FK33_THERM_TRIP     (FK33_THERMP_BASE + 0x8u)
#define FK33_THERMC_BASE    0x{g.THERMC_BASE:08X}u
#define FK33_THERM_CTL      (FK33_THERMC_BASE + 0x0u)   /* write */
#define FK33_THERM_CANARY   (FK33_THERMC_BASE + 0x8u)

/* THERM_CTL[31:16] must be the key or the write does nothing, and both clears
 * are EDGE triggered: write the key with the bit set, then write 0. */
#define FK33_THERM_KEY      0x{g.THERM_CTL_KEY:04X}u
#define FK33_THERM_CLR_TRIP 0x1u
#define FK33_THERM_CLR_PEAK 0x2u

/* THERM_STATUS fields */
#define FK33_THERM_HALTED   (1u << 0)
#define FK33_THERM_WARN     (1u << 1)
#define FK33_THERM_ARMED    (1u << 2)
#define FK33_THERM_DIE_OK   (1u << 3)
#define FK33_THERM_HBM_OK   (1u << 4)
#define FK33_THERM_DIE_HOT  (1u << 5)
#define FK33_THERM_HBM_HOT  (1u << 6)
#define FK33_THERM_TRIPPED  (1u << 7)
#define FK33_THERM_PRESENT  (1u << 31)
#define FK33_THERM_CAUSE(v)      (((v) >> 8) & 0xFu)
#define FK33_THERM_TRIP_CAUSE(v) (((v) >> 12) & 0xFu)
#define FK33_THERM_TRIP_COUNT(v) (((v) >> 16) & 0xFFu)

/* cause codes */
#define FK33_CAUSE_NONE      0u
#define FK33_CAUSE_DIE_OT    1u   /* SYSMON's armed over-temperature alarm */
#define FK33_CAUSE_DIE_ALARM 2u   /* SYSMON user temperature alarm */
#define FK33_CAUSE_DIE_OVER  3u
#define FK33_CAUSE_DIE_STALE 4u   /* not live, or an implausible reading */
#define FK33_CAUSE_HBM_CAT   5u   /* a stack asserted CATTRIP */
#define FK33_CAUSE_HBM_OVER  6u
#define FK33_CAUSE_HBM_STALE 7u

/* The thresholds the bitstream enforces, in degrees C.  The HBM ones are in
 * RAW 7-bit stack-code units: the code-to-Celsius mapping of
 * DRAM_x_STAT_TEMP is NOT calibrated on this card. */
#define FK33_THERM_DIE_WARN    {g.THERM_DIE_WARN_C}
#define FK33_THERM_DIE_HALT    {g.THERM_DIE_HALT_C}
#define FK33_THERM_DIE_RESUME  {g.THERM_DIE_RESUME_C}
#define FK33_THERM_HBM_WARN    {g.THERM_HBM_WARN_C}
#define FK33_THERM_HBM_HALT    {g.THERM_HBM_HALT_C}
#define FK33_THERM_HBM_RESUME  {g.THERM_HBM_RESUME_C}

{render_engine()}
/* ---- PCIe identity ------------------------------------------------------ */
/* Already carried by dma_ip_drivers, so new_id should not be needed. */
#define FK33_PCI_VENDOR     0x10EEu
#define FK33_PCI_DEVICE     0x9034u

#endif /* FK33_REGS_H */
'''


def render_engine():
    """Subsystem A: the engine's control plane and the activation writer.

    Added 2026-08-29 by TRACK AJOBRUN.  Until then this header had no engine
    block at all and `grep -rn '0x12000\\|ENG_CTL' hw/fk33/host/` returned
    nothing, so the card carried a bitstream and 4.49 GB of verified weights
    and no tool in the repository could start an operation on it.

    Three sources, none of them a document:
      gen_pcieep.py            the two base addresses (it configures the BD)
      gen_fk33_engine.py       the synthesis geometry and the ENG1 magic
                               (it generates rtl/fk33_engine.vhd)
      matvec_int4_desc_pkg.vhd MV4I_MAGIC and the error-code space
    """
    g = load_source()
    e = load_engine()
    magic, codes = scrape_desc_pkg()
    L = []
    a = L.append
    a("/* ---- Subsystem A: the matvec engine, rtl/matvec_int4_desc_axi.vhd --- */")
    a("/* Word-addressed, reg = addr[7:2].  CONSTANT AT EVERY GEOMETRY: that is")
    a(" * the whole point of the descriptor-in-memory decision.  Everything that")
    a(" * grows with ROWS_IF/NPORTS_W/AXI_DW lives in the descriptor, in memory.")
    a(" *")
    a(" * DISCOVERY, NOT ASSUMPTION.  ID, ADDR_CAP, CAPS and DESC_WORDS are how a")
    a(" * host learns which build it is talking to.  A driver that assumes the")
    a(" * FK33_ENG_* geometry below instead of reading them is a driver that will")
    a(" * program a stale descriptor into a re-synthesised card and be told")
    a(" * nothing. */")
    a("#define FK33_ENG_CTL_BASE   0x%08Xu" % g.ENG_CTL_BASE)
    for off, name, acc in ENG_REGS:
        a("#define FK33_ENG_%-12s (FK33_ENG_CTL_BASE + 0x%02Xu)  /* %-2s */"
          % (name, off, acc))
    a("")
    a("#define FK33_ENG_ID_MAGIC   0x%08Xu   /* \"MV4I\" */" % magic)
    a("#define FK33_ENG_GO         0x1u          /* CTRL bit 0, self-clearing */")
    a("")
    a("/* STATUS.  `done` is latched and cleared by the next GO; `err` is sticky")
    a(" * until reset, and a rejected descriptor sets err WITHOUT setting done.")
    a(" * So poll for (done | err): a host polling for done alone hangs, which is")
    a(" * deliberate -- it is what stops a driver reading stale results. */")
    a("#define FK33_ENG_ST_DONE     (1u << 0)")
    a("#define FK33_ENG_ST_BUSY     (1u << 1)")
    a("#define FK33_ENG_ST_ERR      (1u << 2)")
    a("#define FK33_ENG_ST_SAT      (1u << 3)   /* sticky saturation event */")
    a("#define FK33_ENG_ST_ERR_ADDR (1u << 4)   /* sticky; latched at WRITE time */")
    a("#define FK33_ENG_ST_CODE(v)  (((v) >> 8) & 0xFu)")
    a("")
    a("/* ERR_INFO carries the failing descriptor WORD index, or this sentinel")
    a(" * for the pointer itself. */")
    a("#define FK33_ENG_EI_PTR     0xFFFFu")
    a("")
    a("/* Error codes, from rtl/matvec_int4_desc_pkg.vhd.  0x1, 0x2 and 0x5..0x8")
    a(" * are subsystem D's and are deliberately absent here. */")
    for name, val in codes:
        a("#define FK33_ENG_%-9s 0x%Xu" % (name, val))
    a("")
    a("/* CAPS packs the four geometry constants the build was synthesised with. */")
    a("#define FK33_ENG_CAPS_NPORTS_W(v) (((v) >>  0) & 0xFFu)")
    a("#define FK33_ENG_CAPS_NPORTS_S(v) (((v) >>  8) & 0xFFu)")
    a("#define FK33_ENG_CAPS_ROWS_IF(v)  (((v) >> 16) & 0xFFu)")
    a("#define FK33_ENG_CAPS_AXI_B(v)    (((v) >> 24) & 0xFFu)  /* AXI_DW/8 */")
    a("")
    a("/* What THIS bitstream was built with (hw/fk33/gen_fk33_engine.py).  Use")
    a(" * these to CHECK what CAPS/ADDR_CAP/DESC_WORDS report, never in place of")
    a(" * reading them. */")
    a("#define FK33_ENG_ROWS_IF     %d" % e.ROWS_IF)
    a("#define FK33_ENG_BLK         %d" % e.BLK)
    a("#define FK33_ENG_NPORTS_W    %d" % e.NPORTS_W)
    a("#define FK33_ENG_NPORTS_S    %d" % e.NPORTS_S)
    a("#define FK33_ENG_AXI_DW      %d" % e.AXI_DW)
    a("#define FK33_ENG_ADDR_W      %d" % e.ADDR_W)
    a("#define FK33_ENG_MAXCOLS     %d" % e.MAXCOLS)
    a("#define FK33_ENG_MAXROWS_BFP %d" % e.MAXROWS_BFP)
    a("#define FK33_ENG_MAXB        %d" % e.MAXB)
    a("#define FK33_ENG_DESC_MAXB   %d" % e.DESC_MAXB)
    a("/* DESC_PTR must be aligned to DESC_MAXB*AXI_DW/8.  Alignment replaces a")
    a(" * 4 KB burst splitter in rtl/axi_rd_port.vhd; ERR_ALIGN otherwise. */")
    a("#define FK33_ENG_DESC_ALIGN  %d" % (e.DESC_MAXB * e.AXI_DW // 8))
    a("/* DESC_WORDS = 8 header + nsub_w + nsub_s + 4 extension, 64-bit words. */")
    a("#define FK33_ENG_DESC_WORDS_EXPECT %d" % (8 + e.NPORTS_W + e.NPORTS_S + 4))
    a("#define FK33_ENG_HBM_ADDR_W  %d   /* the SAXI port; 40->33 is TRUNCATED */"
      % e.HBM_ADDR_W)
    a("")
    a("/* ---- The activation writer, rtl/fk33_engine.vhd --------------------- */")
    a("/* matvec_int4_desc_axi has no X_IDX/X_DATA of its own: activations arrive")
    a(" * on x_we/x_waddr/x_wdata from the previous stage.  In THIS bitstream")
    a(" * there is no previous stage, so without this port the only thing the")
    a(" * card could compute is a matvec against an all-zero x -- which is not")
    a(" * arithmetic anyone can check.  Writing X_DATA drives one element at")
    a(" * X_ADDR and post-increments X_ADDR, so a vector is one burst of writes")
    a(" * to a single address. */")
    a("#define FK33_ENGX_BASE      0x%08Xu" % g.ENG_XW_BASE)
    for off, name, acc in ENGX_REGS:
        a("#define FK33_ENGX_%-10s (FK33_ENGX_BASE + 0x%02Xu)  /* %-2s */"
          % (name, off, acc))
    a("#define FK33_ENGX_ID_MAGIC  0x%08Xu   /* \"ENG1\" */" % e.ENG_MAGIC)
    a("")
    a("/* ENGX_STAT.  GO_BLOCKED is the one that matters on this card: the")
    a(" * thermal guard masks CTRL bit 0 while compute_halt is high, and open")
    a(" * issue THERM-255 has that guard tripping roughly once every three")
    a(" * minutes for reasons that are not heat.  A GO swallowed by the halt")
    a(" * presents as a job that never starts, so clear this bit before GO and")
    a(" * read it after: a set bit says the command was refused, not that the")
    a(" * engine is slow. */")
    a("#define FK33_ENGX_ST_HALT       (1u << 0)   /* live compute_halt */")
    a("#define FK33_ENGX_ST_GO_BLOCKED (1u << 1)   /* sticky; write 1 to clear */")
    a("#define FK33_ENGX_ST_JOB_DONE   (1u << 2)")
    a("#define FK33_ENGX_ST_JOB_ERR    (1u << 3)")
    a("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the checked-in header matches, exit 1 if not")
    args = ap.parse_args()

    # The register-table check runs on BOTH paths.  On --check it is the point;
    # on a write it stops a shifted table from being baked into the header and
    # then reported as "in step" by the very next --check.
    bad = check_reg_table()
    if bad:
        print("MISMATCH: " + bad, file=sys.stderr)
        return 1

    text = render(load_source())

    if args.check:
        if not TARGET.exists():
            print(f"MISSING: {TARGET} does not exist", file=sys.stderr)
            return 1
        if TARGET.read_text() != text:
            print(f"STALE: {TARGET} does not match hw/fk33/gen_pcieep.py.\n"
                  f"  Regenerate with: python3 {pathlib.Path(__file__).name}\n"
                  f"  Do NOT hand-edit the header -- gen_pcieep.py decides what "
                  f"the hardware does, and this file only reports it.",
                  file=sys.stderr)
            return 1
        print("fk33_regs.h is in step with gen_pcieep.py")
        return 0

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(text)
    print(f"wrote {TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
