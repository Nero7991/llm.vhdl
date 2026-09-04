#!/usr/bin/env python3
"""Refuse any block-design module cell whose entity Vivado's IP packager
cannot infer.

WHY THIS EXISTS.  The pcieep bitstream build was dead from 3a145fd until
2026-09-03 and nobody knew, because NOTHING SCHEDULES `pcieep_build.sh`.  One
of the two defects was `rtl/fk33_seam.vhd` declaring four ports as `natural`:

    ERROR: [IP_Flow 19-734] Port type 'natural' is not recognized.  Only
      std_logic and std_logic_vector types are allowed for ports.
    ERROR: [IP_Flow 19-4668] Failed to infer definition from module 'fk33_seam'
    ERROR: [BD 41-1699] Unable to add reference type cell ... 'fk33_seam'

That is legal VHDL.  It elaborates, it simulates, every bench passes, and no
amount of simulation can ever see it -- the constraint belongs to the packager,
not to the language.  So the ONLY thing that catches it is a build, and the
build costs 3 minutes and 3.4 GB of Vivado.  This check costs milliseconds and
catches the same class statically.

It also catches the SECOND rule, which is invisible until the first is fixed:

    ERROR: [IP_Flow 19-627] Unsupported function call "clog2" in the expression

A block-design port WIDTH is an XPath expression over the cell's generics,
evaluated by the packager, NOT by VHDL.  It may reference a generic and do
arithmetic on it; it may NOT call a function, however trivially that function
evaluates.  `std_logic_vector(clog2(NREG)-1 downto 0)` is correct VHDL and is
rejected.  Carry the width as its own generic instead.

WHAT IT DOES NOT DO.  This is a check on the ENTITY, not on the block design.
It cannot tell you that a cell is wired wrongly, that an address map is wrong,
or that anything downstream of `create_bd_cell` fails.  A green run here means
one specific class of packager refusal is absent, nothing more.  `--bd-only`
remains the real test and this does not replace it.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Where `create_bd_cell -type module -reference X` may appear.  Both the
# generator and its generated output are scanned: the generator is the source
# of truth, and the .tcl is what actually runs, so a divergence between them is
# itself worth failing on.
CELL_SOURCES = [
    "hw/fk33/gen_pcieep.py",
    "hw/fk33/build_fk33_pcieep.tcl",
    "hw/fk33/gen_hbmbw.py",
    "hw/fk33/build_fk33_hbmbw.tcl",
]

# Where the entities live.
RTL_DIRS = ["rtl", "hw/fk33/rtl"]

CELL_RE = re.compile(
    r"create_bd_cell\s+-type\s+module\s+-reference\s+([A-Za-z_]\w*)")

# A port line inside an entity's port clause:  name(s) : dir type ;
PORT_RE = re.compile(
    r"^\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*"
    r"(in|out|inout|buffer)\s+(.+?)\s*(?:;|\)\s*;)?\s*$",
    re.IGNORECASE)

ALLOWED_SCALAR = ("std_logic", "std_ulogic")

# `signed` and `unsigned` ARE accepted, despite 19-734's wording ("Only
# std_logic and std_logic_vector types are allowed").  MEASURED 2026-09-03: the
# `--bd-only` run that succeeded had ELEVEN such ports on `fk33_seam` -- e.g.
# `hw_data : out signed(MANT_W-1 downto 0)` -- and the packager named ONLY the
# four `natural` ones.  It examined every port and complained about exactly one
# class, so this is a direct observation and not an inference from silence.
#
# The first version of this file trusted the error TEXT instead and reported 11
# failures against RTL that demonstrably builds.  That is the house failure
# mode written down in CLAUDE.md: a check that has never been shown to
# discriminate on the thing it guards.  Its teeth are recorded at the bottom of
# this file.
ALLOWED_VECTOR = ("std_logic_vector", "std_ulogic_vector",
                  "signed", "unsigned")


def strip_comments(text):
    return re.sub(r"--[^\n]*", "", text)


def find_entity(name):
    """Return (path, entity_text) for `entity <name> is ... end`."""
    for d in RTL_DIRS:
        dd = os.path.join(REPO, d)
        if not os.path.isdir(dd):
            continue
        for fn in sorted(os.listdir(dd)):
            if not fn.endswith(".vhd"):
                continue
            path = os.path.join(dd, fn)
            with open(path, "r", errors="replace") as fh:
                src = fh.read()
            m = re.search(r"^\s*entity\s+" + re.escape(name) + r"\s+is\b",
                          src, re.IGNORECASE | re.MULTILINE)
            if not m:
                continue
            end = re.search(r"^\s*end\s+(entity\s+)?" + re.escape(name)
                            + r"?\s*;", src[m.start():],
                            re.IGNORECASE | re.MULTILINE)
            stop = m.start() + (end.end() if end else len(src) - m.start())
            return os.path.relpath(path, REPO), src[m.start():stop]
    return None, None


def port_clause(entity_text):
    """The text between `port (` and its matching `)`.  Depth-counted, because
    a port type may itself contain parentheses."""
    m = re.search(r"\bport\s*\(", entity_text, re.IGNORECASE)
    if not m:
        return ""
    i = m.end()
    depth = 1
    while i < len(entity_text) and depth:
        if entity_text[i] == "(":
            depth += 1
        elif entity_text[i] == ")":
            depth -= 1
        i += 1
    return entity_text[m.end():i - 1]


def check_port(names, typ):
    """Return a list of problem strings for one port declaration."""
    bad = []
    t = typ.strip().rstrip(";").strip()
    # Drop a default initialiser:  ... := '0'
    t = re.split(r":=", t)[0].strip()
    low = t.lower()

    vec = None
    for v in ALLOWED_VECTOR:
        if low.startswith(v) and (len(low) == len(v) or not low[len(v)].isalnum()):
            vec = v
            break

    if vec is None:
        if low in ALLOWED_SCALAR:
            return bad
        bad.append("%s : type %r is not std_logic or std_logic_vector "
                   "[IP_Flow 19-734]" % (names, t))
        return bad

    # It IS a vector.  Its range expression may not call a function.
    rng = t[len(vec):].strip()
    if not rng.startswith("("):
        return bad
    inner = rng[1:rng.rfind(")")] if rng.rfind(")") > 0 else rng[1:]
    # A function call is an identifier immediately followed by "(".  Numeric
    # conversions are not present in a port range in this codebase; anything
    # that looks like a call is refused, which is exactly the packager's rule.
    for call in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", inner):
        bad.append("%s : range %r calls %r; a block-design port width is an "
                   "XPath expression over the generics and cannot call a VHDL "
                   "function [IP_Flow 19-627].  Carry the width as its own "
                   "generic." % (names, inner.strip(), call.group(1)))
    return bad


def main():
    cells = {}
    for rel in CELL_SOURCES:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            continue
        with open(path, "r", errors="replace") as fh:
            body = fh.read()
        for m in CELL_RE.finditer(body):
            cells.setdefault(m.group(1), []).append(rel)

    if not cells:
        print("BD_PORTS FAIL: found no `create_bd_cell -type module "
              "-reference` anywhere in %s.  Either the build scripts moved or "
              "this check's file list is stale; a check that inspects nothing "
              "passes vacuously and is worse than no check."
              % ", ".join(CELL_SOURCES))
        return 1

    nbad = 0
    nchecked = 0
    nports = 0
    for name in sorted(cells):
        path, ent = find_entity(name)
        if ent is None:
            print("BD_PORTS FAIL: cell %r is instantiated by %s but no "
                  "`entity %s is` was found under %s."
                  % (name, ", ".join(sorted(set(cells[name]))), name,
                     " or ".join(RTL_DIRS)))
            nbad += 1
            continue
        nchecked += 1
        clause = strip_comments(port_clause(ent))
        if not clause.strip():
            print("BD_PORTS FAIL: cell %r (%s) has no port clause this check "
                  "could read." % (name, path))
            nbad += 1
            continue
        for line in clause.split(";"):
            line = line.strip()
            if not line:
                continue
            m = PORT_RE.match(line.replace("\n", " "))
            if not m:
                continue
            nports += 1
            for problem in check_port(m.group(1), m.group(3)):
                print("BD_PORTS FAIL: %s: %s" % (path, problem))
                nbad += 1

    if nports == 0:
        print("BD_PORTS FAIL: parsed 0 ports across %d entities.  The port "
              "regex no longer matches this codebase's style; it would pass "
              "for every possible defect." % nchecked)
        return 1

    if nbad:
        print("BD_PORTS FAIL: %d problem(s) across %d cell(s), %d ports."
              % (nbad, nchecked, nports))
        return 1

    print("BD_PORTS PASS: %d block-design module cells, %d ports, all "
          "std_logic/std_logic_vector with function-free widths (%s)"
          % (nchecked, nports, ", ".join(sorted(cells))))
    return 0


if __name__ == "__main__":
    sys.exit(main())

# ---------------------------------------------------------------------------
# TEETH.  MEASURED 2026-09-03 on a scratch copy of the tree, one mutation at a
# time, each restored before the next.  A checker never shown to fail has not
# been shown to work.
#
#   M1  `hw_reg` back to `natural range 0 to NREG-1`      KILLED  19-734
#       -> "hw_reg : type 'natural range 0 to NREG-1' is not std_logic ..."
#          This is the ACTUAL defect that killed the build; the mutation
#          reconstructs it exactly.
#
#   M2  `hw_addr` width back to `clog2(REGMAX)-1`         KILLED  19-627
#       -> "range 'clog2(REGMAX)-1 downto 0' calls 'clog2'"
#          This is the SECOND defect, the one only visible after M1 is fixed.
#
#   M3  `entity fk33_seam` renamed                        KILLED
#       -> "cell 'fk33_seam' is instantiated by ... but no entity ... found"
#          Guards against the check silently skipping a cell it cannot locate.
#
#   M4  every `create_bd_cell -type module` line broken   KILLED
#       -> "found no `create_bd_cell -type module -reference` anywhere ...
#           a check that inspects nothing passes vacuously"
#          Guards against the whole check going vacuous if the build scripts
#          are restructured.  Without this arm M4 would have PASSED.
#
#   M7  `signed(clog2(MANT_W)-1 downto 0)`                KILLED  19-627
#       -> proves the width rule is applied to signed/unsigned too, not only
#          to std_logic_vector.
#
# CONTROLS -- mutations that must NOT bite, and did not.  These are the
# valuable rows: they measure what the check does NOT claim.
#
#   M5  a new `unsigned(HADDR_W-1 downto 0)` port on a BD cell    PASS
#       Port count 1860 -> 1861, so the port WAS parsed and WAS accepted.
#       Without this the M1 kill would be consistent with a check that simply
#       refuses everything that is not literally `std_logic_vector`.
#
#   M6  a `natural` port added to `llama_top`, which is NOT a BD cell  PASS
#       Port count stayed 1860, i.e. llama_top was never scanned.  This is the
#       control that distinguishes "checks block-design cells" from "greps the
#       tree for the word natural" -- the latter would fire on dozens of
#       entities that are correct, and would be deleted within a week.
