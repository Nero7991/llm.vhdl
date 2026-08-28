#!/usr/bin/env python3
"""Port-map conformance for the `library beh` netlist-compare testbenches.

WHY THIS EXISTS.  sim/regress.sh classifies any testbench declaring
`library beh` as a post-synthesis netlist-vs-behavioural compare and SKIPS it
on sight, because running one needs xsim plus UNISIM and the gate has neither.
That reason is true.  The consequence is that no gate ever elaborates these
files, so a port that is renamed, added or removed on the behavioural entity
leaves the testbench referring to a signature that no longer exists, and the
gate reports SKIPPED rather than red.  The failure is invisible until someone
runs the xsim job by hand, which by then is months later.

This is not hypothetical.  `sim/tb_bfp_cmp.vhd` port-maps `in_q` on
`beh.bfp_pack`, a bus the entity lost when its input became a read-ahead BRAM
port (`o_raddr` out, `i_rdata` in).  The testbench cannot elaborate against the
committed RTL and has not been able to for some time.  It sat as SKIPPED, and a
SKIPPED line removes a red line rather than adding one.

WHAT IS AND IS NOT A FAILURE.  A formal in the port map that the entity does
not declare is a hard error: the file cannot elaborate.  An entity port that
the testbench does NOT map is reported but is NOT an error, because VHDL leaves
an unassociated output open and these entities carry debug and probe outputs
that a compare bench has no reason to observe.  Conflating the two would make
the check cry wolf on twelve healthy files.

SCOPE.  This is a shallow parse over entity declarations and named port maps.
It does not typecheck, does not check widths, and does not check direction.  It
answers exactly one question, the one that actually rotted: does every formal
named in a `beh.<entity>` port map exist on that entity today.

PARSING, AND TWO TRAPS THE TEETH CHECK CAUGHT IN THIS FILE ITSELF.  A first
version took formals with the regex `(\w+)\s*=>` over the port map text.  That
is wrong twice.  An aggregate used as an ACTUAL, `i_rdata => (others => '0')`,
yields a spurious formal named `others`; and a non-greedy `\((.*?)\)\s*;` ends
the port map at the first `);` it meets, which a nested paren reaches early.
Both are fixed by scanning parentheses: the port map is extracted by balancing,
then split on commas AT DEPTH ZERO, and the formal is whatever precedes the
first `=>` in each top-level element.  Anything nested is an actual and is not
inspected.

Exit status: 0 all conformant, 1 at least one stale, 2 an entity was not found.
"""

import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEARCH = ("rtl", "sim", "sim/micro", "tb")


def strip_comments(text: str) -> str:
    return re.sub(r"--[^\n]*", "", text)


def entity_ports(dirs=SEARCH):
    """name -> (set of port names, defining file) for every entity found."""
    out = {}
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(REPO, d, "*.vhd"))):
            src = strip_comments(open(path, errors="replace").read())
            for m in re.finditer(r"\bentity\s+(\w+)\s+is(.*?)\bend\b", src,
                                 re.S | re.I):
                name = m.group(1).lower()
                pm = re.search(r"\bport\s*\((.*)\)\s*;", m.group(2), re.S | re.I)
                if not pm:
                    continue
                names = set()
                for decl in pm.group(1).split(";"):
                    if ":" not in decl:
                        continue
                    for n in decl.split(":")[0].split(","):
                        n = n.strip().lower()
                        if re.fullmatch(r"\w+", n):
                            names.add(n)
                # first definition wins; rtl/ is searched before sim/
                out.setdefault(name, (names, os.path.relpath(path, REPO)))
    return out


def balanced(text: str, open_at: int) -> str:
    """Substring inside the parens starting at `open_at`, respecting nesting."""
    depth, i = 0, open_at
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_at + 1:i]
        i += 1
    return ""


def formals_of(portmap: str):
    """Formal names in a named port map, ignoring anything inside an actual."""
    out, depth, cur = set(), 0, []
    for ch in portmap + ",":
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            elem = "".join(cur)
            if "=>" in elem:
                lhs = elem.split("=>", 1)[0].strip().lower()
                if re.fullmatch(r"\w+", lhs):
                    out.add(lhs)
            cur = []
        else:
            cur.append(ch)
    return out


def beh_instances(src: str):
    """(entity_name, port_map_text) for each `entity beh.X ... port map (...)`."""
    for m in re.finditer(r"entity\s+beh\.(\w+)", src, re.I):
        rest = src[m.end():]
        pm = re.search(r"\bport\s+map\s*\(", rest, re.I)
        if not pm:
            continue
        # a `generic map (...)` may sit between; balanced() handles its parens
        yield m.group(1).lower(), balanced(rest, pm.end() - 1)


def beh_testbenches():
    for d in ("sim", "tb"):
        for path in sorted(glob.glob(os.path.join(REPO, d, "tb_*.vhd"))):
            src = strip_comments(open(path, errors="replace").read())
            if re.search(r"^[ \t]*library[ \t]+beh[ \t]*;", src, re.M | re.I):
                yield os.path.relpath(path, REPO), src


def main() -> int:
    ports = entity_ports()
    stale, notfound, checked = [], [], 0

    for rel, src in beh_testbenches():
        for ent, portmap in beh_instances(src):
            formals = formals_of(portmap)
            checked += 1
            if ent not in ports:
                notfound.append((rel, ent))
                continue
            have, where = ports[ent]
            bad = sorted(formals - have)
            if bad:
                stale.append((rel, ent, where, bad, sorted(have - formals)))

    print("check_beh_ports: %d port map(s) across the `library beh` class"
          % checked)
    for rel, ent, where, bad, unmapped in stale:
        print("  STALE %s" % rel)
        print("        entity beh.%s, declared in %s" % (ent, where))
        print("        formals not on the entity: %s" % ", ".join(bad))
        if unmapped:
            print("        (entity ports left open, not an error: %s)"
                  % ", ".join(unmapped))
    for rel, ent in notfound:
        print("  NO ENTITY %s references beh.%s, which nothing in %s defines"
              % (rel, ent, ", ".join(SEARCH)))

    if notfound:
        return 2
    if stale:
        print("check_beh_ports: FAIL, %d stale port map(s)" % len(stale))
        return 1
    print("check_beh_ports: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
