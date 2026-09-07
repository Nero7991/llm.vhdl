#!/usr/bin/env python3
"""Emit a BLOCK-DESIGN-LEGAL wrapper around an entity the IP packager refuses.

WHY THIS EXISTS.  `compose4_top --wire --mem` is the design the card needs, and
`sim/check_bd_ports.py` refuses **35** of its 1,310 ports:

    22  [IP_Flow 19-734]  `integer` / `natural` are not port types
    13  [IP_Flow 19-627]  a port width may not call a function (`clog2`)

Neither is reachable by any bench -- they are packager rules, not language
rules, so the RTL elaborates, simulates and passes every row while the block
design cannot instantiate it. The measured cost of finding that out the other
way is a `--bd-only` build: 3 minutes and 3.4 GB, and nothing schedules it.

WHAT IT DOES NOT DO.  It does not change the design. It emits a wrapper whose
ports are the same signals in legal types, and converts at the boundary. A
wrapper is the right tool BECAUSE the offending ports are mostly internal seams
that a real card top will terminate rather than export -- rewriting 22 entity
ports across B, C and D to please a packager would be changing verified RTL for
a tooling constraint.

THE TWO CONVERSIONS.

  `integer range 0 to N-1`   ->  std_logic_vector(W-1 downto 0), W = clog2(N)
      out: std_logic_vector(to_unsigned(inner, W))
      in : to_integer(unsigned(outer))
      W is computed HERE and emitted as a LITERAL, because a width that calls
      a function is the very thing 19-627 refuses.

  `unsigned(clog2(X)-1 downto 0)`  ->  unsigned(K-1 downto 0), K = clog2(X)
      No conversion: the type is already accepted (MEASURED -- 19-734's
      wording says otherwise and is wrong; see check_bd_ports.py:68). Only the
      function call in the WIDTH has to go, so the width is evaluated here.

`clog2` is evaluated the way `rtl/util_pkg.vhd` defines it: the smallest n with
2**n >= x, and 0 for x <= 1.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "sim"))
import check_bd_ports as C


def clog2(x):
    """rtl/util_pkg.vhd's clog2: smallest n with 2**n >= x, 0 for x <= 1."""
    if x <= 1:
        return 0
    n = 0
    while (1 << n) < x:
        n += 1
    return n


SAFE = re.compile(r"^[0-9\s()+\-*/]+$")

# Textual substitutions for names a port range mentions that this tool cannot
# evaluate: package constants and functions of a generic.  DELIBERATELY
# EXPLICIT and supplied on the command line, never inferred, because a wrong
# width here is a silently wrong wrapper rather than an error -- and the
# project has a recorded case of a generic that had to agree with a derived
# value being pinned two-sided for exactly this reason.
#
# Get the values FROM THE VHDL, not from a comment.  A three-line GHDL probe
# reporting `NREGION` and `region_max(mk_shape(MODEL, NCARDS))` is the source;
# MEASURED 2026-09-07 they are 14 and 12288.
CONSTS = {}


def const_eval(expr):
    """Evaluate a width expression that contains only literals and clog2().

    Returns None if anything else appears.  Deliberately NOT a general
    evaluator: a width that depends on a generic must stay symbolic, and one
    that calls something other than clog2 is not understood and must be
    reported rather than guessed at.
    """
    e = expr.strip()
    # Apply the caller's explicit substitutions first, longest name first so
    # that `region_max(RG_SHAPE)` is consumed before any shorter overlapping
    # key could bite into it.
    for k in sorted(CONSTS, key=len, reverse=True):
        e = e.replace(k, str(CONSTS[k]))
    # Fold innermost parenthesised ARITHMETIC first.  Without this,
    # `clog2(2*(256)*(16))` never matches a clog2 pattern that forbids nested
    # parentheses, and the port is reported unhandled -- which is what the
    # first draft did on all 11 of C's ports.
    for _ in range(16):
        # The negative lookbehind is load-bearing: without it this folder
        # eats the FUNCTION'S OWN parentheses -- `clog2(2*256*16)` becomes
        # `clog28192` -- and the clog2 pass then matches nothing, so every
        # port is reported unhandled for a reason that looks like the
        # opposite of the one that applies.
        m = re.search(r"(?<![A-Za-z_0-9])\(\s*([0-9][0-9\s+\-*/]*)\s*\)", e)
        if not m:
            break
        try:
            e = e[:m.start()] + str(int(eval(m.group(1),
                                             {"__builtins__": {}}, {}))) + e[m.end():]
        except Exception:
            return None
    # then resolve clog2(...) calls, whose arguments are now literal
    for _ in range(8):
        m = re.search(r"clog2\s*\(([^()]*)\)", e)
        if not m:
            break
        inner = m.group(1)
        if not SAFE.match(inner):
            return None
        try:
            v = clog2(int(eval(inner, {"__builtins__": {}}, {})))
        except Exception:
            return None
        e = e[:m.start()] + str(v) + e[m.end():]
    if "(" in e and not SAFE.match(e):
        return None
    if not SAFE.match(e):
        return None
    try:
        return int(eval(e, {"__builtins__": {}}, {}))
    except Exception:
        return None


INT_RANGE = re.compile(
    r"^(integer|natural|positive)\s+range\s+(.+?)\s+to\s+(.+)$", re.I)


def classify(typ):
    """Return (kind, info) for one port type string."""
    t = re.split(r":=", typ.strip().rstrip(";"))[0].strip()
    low = t.lower()

    m = INT_RANGE.match(t)
    if m:
        lo, hi = const_eval(m.group(2)), const_eval(m.group(3))
        if lo is None or hi is None or lo != 0:
            return ("unhandled", t)
        return ("int", (hi + 1, max(1, clog2(hi + 1))))

    if low in ("integer", "natural", "positive"):
        # An unconstrained integer port.  32 bits is the VHDL integer width and
        # is the only defensible choice, but it is a JUDGEMENT and is reported.
        return ("int32", t)

    for v in C.ALLOWED_VECTOR:
        if low.startswith(v) and (len(low) == len(v)
                                  or not low[len(v)].isalnum()):
            rng = t[len(v):].strip()
            if not rng.startswith("("):
                return ("ok", t)
            inner = rng[1:rng.rfind(")")]
            if not re.search(r"\b[A-Za-z_]\w*\s*\(", inner):
                return ("ok", t)
            # width calls a function: try to fold it to a literal
            m2 = re.match(r"^(.*?)\s+downto\s+(.*)$", inner, re.I)
            if not m2:
                return ("unhandled", t)
            hi, lo = const_eval(m2.group(1)), const_eval(m2.group(2))
            if hi is None or lo is None:
                return ("unhandled", t)
            return ("fold", (v, hi, lo))

    if low in C.ALLOWED_SCALAR:
        return ("ok", t)
    return ("unhandled", t)


def parse_entity(path, name):
    src = open(path, errors="replace").read()
    m = re.search(r"\bentity\s+%s\s+is\b(.*?)\bend\s+(entity|%s)\b"
                  % (re.escape(name), re.escape(name)), src, re.S | re.I)
    if not m:
        sys.exit("gen_bd_wrapper: no `entity %s is` in %s" % (name, path))
    body = m.group(1)
    clause = C.strip_comments(C.port_clause("entity x is" + body + "end entity"))
    ports = []
    for line in clause.split(";"):
        line = line.strip()
        if not line:
            continue
        mm = C.PORT_RE.match(line.replace("\n", " "))
        if not mm:
            continue
        for nm in [x.strip() for x in mm.group(1).split(",")]:
            ports.append((nm, mm.group(2).lower(), mm.group(3).strip()))
    return ports


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="file holding the entity")
    ap.add_argument("--entity", required=True, help="entity to wrap")
    ap.add_argument("--out", required=True)
    ap.add_argument("--wrapper", default="")
    ap.add_argument("--const", action="append", default=[],
                    metavar="NAME=VALUE",
                    help="substitute NAME with VALUE in port range "
                         "expressions. Required for any range naming a package "
                         "constant or a function of a generic; the tool "
                         "refuses rather than guessing. e.g. "
                         "--const NREGION=14 "
                         "--const 'region_max(RG_SHAPE)=12288'")
    a = ap.parse_args()
    wname = a.wrapper or (a.entity + "_bd")
    for kv in a.const:
        if "=" not in kv:
            sys.exit("gen_bd_wrapper: --const wants NAME=VALUE, got %r" % kv)
        k, v = kv.rsplit("=", 1)
        try:
            CONSTS[k.strip()] = int(v)
        except ValueError:
            sys.exit("gen_bd_wrapper: --const %r value is not an integer" % kv)

    ports = parse_entity(a.src, a.entity)
    decls, maps, sigs, pre, post = [], [], [], [], []
    n_int = n_fold = n_ok = 0
    unhandled = []

    for nm, direction, typ in ports:
        kind, info = classify(typ)
        if kind == "ok":
            decls.append("    %-24s : %-6s %s" % (nm, direction, info))
            maps.append("      %-24s => %s" % (nm, nm))
            n_ok += 1
        elif kind == "fold":
            v, hi, lo = info
            decls.append("    %-24s : %-6s %s(%d downto %d)"
                         % (nm, direction, v, hi, lo))
            maps.append("      %-24s => %s" % (nm, nm))
            n_fold += 1
        elif kind == "int32":
            # An unconstrained `integer`.  VHDL's integer is 32-bit SIGNED, so
            # `signed(31 downto 0)` is the faithful carrier -- and `signed` is
            # an accepted port type (MEASURED; 19-734's wording says otherwise
            # and is wrong).  No vector conversion is needed, only the
            # integer/signed conversion.
            sig = "w_" + nm
            sigs.append("  signal %-22s : integer;" % sig)
            decls.append("    %-24s : %-6s signed(31 downto 0)" % (nm, direction))
            maps.append("      %-24s => %s" % (nm, sig))
            if direction == "in":
                pre.append("  %s <= to_integer(%s);" % (sig, nm))
            else:
                post.append("  %s <= to_signed(%s, 32);" % (nm, sig))
            n_int += 1
        elif kind == "int":
            n, w = info
            sig = "w_" + nm
            sigs.append("  signal %-22s : integer range 0 to %d;" % (sig, n - 1))
            decls.append("    %-24s : %-6s std_logic_vector(%d downto 0)"
                         % (nm, direction, w - 1))
            maps.append("      %-24s => %s" % (nm, sig))
            if direction == "in":
                pre.append("  %s <= to_integer(unsigned(%s));" % (sig, nm))
            else:
                post.append("  %s <= std_logic_vector(to_unsigned(%s, %d));"
                            % (nm, sig, w))
            n_int += 1
        else:
            unhandled.append((nm, direction, typ))

    if unhandled:
        print("gen_bd_wrapper: %d port(s) this tool does not understand; it "
              "refuses rather than guessing:" % len(unhandled))
        for nm, d, t in unhandled[:12]:
            print("    %s : %s %s" % (nm, d, t))
        return 1

    out = []
    w = out.append
    w("-- %s -- GENERATED by tools/gen_bd_wrapper.py from `%s`."
      % (os.path.relpath(a.out, REPO), a.entity))
    w("-- DO NOT HAND-EDIT; edit the generator.")
    w("--")
    w("-- A BLOCK-DESIGN-LEGAL face for an entity the IP packager refuses.")
    w("-- It changes NO logic: every port is the same signal in a type the")
    w("-- packager accepts, converted at the boundary.")
    w("--   %4d ports passed through unchanged" % n_ok)
    w("--   %4d vector widths folded to literals   [IP_Flow 19-627]" % n_fold)
    w("--   %4d integer/natural ports re-typed      [IP_Flow 19-734]" % n_int)
    w("library ieee;")
    w("use ieee.std_logic_1164.all;")
    w("use ieee.numeric_std.all;")
    w("")
    w("entity %s is" % wname)
    w("  port(")
    w(";\n".join(decls))
    w("  );")
    w("end entity;")
    w("")
    w("architecture wrap of %s is" % wname)
    for s in sigs:
        w(s)
    w("begin")
    for p in pre:
        w(p)
    for p in post:
        w(p)
    w("  u : entity work.%s" % a.entity)
    w("    port map(")
    w(",\n".join(maps))
    w("    );")
    w("end architecture;")
    open(a.out, "w").write("\n".join(out) + "\n")
    print("BD_WRAPPER wrote %s: %d ports (%d passthrough, %d folded, %d retyped)"
          % (a.out, len(ports), n_ok, n_fold, n_int))
    return 0


if __name__ == "__main__":
    sys.exit(main())
