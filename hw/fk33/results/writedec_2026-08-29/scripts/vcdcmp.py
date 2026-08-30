#!/usr/bin/env python3
"""TRACK WRITEDEC.  Compare two GHDL VCD dumps SIGNAL BY SIGNAL, by NAME.

WHY THIS EXISTS.  A plain `diff` of two VCDs is not an equivalence test: GHDL
assigns identifier codes in declaration order, so adding ONE signal renumbers
every code after it and the whole file differs while every value is identical.
That is exactly what happened comparing attn_block before and after -- the new
`vs2_flat` shifted `b"` to `c"` and the diff was 100% noise.

This maps id -> name in each file, restricts to the names PRESENT IN BOTH, and
compares the timestamped value-change stream per name.  Signals that exist only
in the new file (the ones the change introduces) are listed and excluded, and
signals that DISAPPEARED are reported as an error rather than ignored, because a
vanished signal is a real difference.

Exit 0 only if every common signal has an identical value history at every
timestamp.  Prints the first mismatches.
"""
import sys, re

def parse(path):
    ids, names = {}, {}
    stream = {}          # name -> list of (time, value)
    t = 0
    defs = True
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if defs:
                if line.startswith('$var'):
                    p = line.split()
                    # $var reg <width> <id> <name> $end   (id may contain spaces? no)
                    idc = p[3]; nm = p[4]
                    ids[idc] = nm; names[nm] = idc
                elif line.startswith('$enddefinitions'):
                    defs = False
                continue
            if not line: continue
            if line[0] == '#':
                t = int(line[1:]); continue
            if line[0] in 'bBrR':
                sp = line.rfind(' ')
                val, idc = line[:sp], line[sp+1:]
            elif line[0] == '$':
                continue
            else:
                val, idc = line[0], line[1:]
            nm = ids.get(idc)
            if nm is None: continue
            stream.setdefault(nm, []).append((t, val))
    return names, stream

an, ast = parse(sys.argv[1])
bn, bst = parse(sys.argv[2])
common = set(an) & set(bn)
only_a = sorted(set(an) - common)
only_b = sorted(set(bn) - common)
print("signals: %d in A, %d in B, %d common" % (len(an), len(bn), len(common)))
if only_a: print("  ONLY IN A (disappeared -- this is a REAL difference): %s" % ", ".join(only_a))
if only_b: print("  only in B (introduced by the change, excluded): %s" % ", ".join(only_b))
bad = 0
for nm in sorted(common):
    a = ast.get(nm, []); b = bst.get(nm, [])
    if a != b:
        bad += 1
        if bad <= 8:
            # first differing entry
            k = 0
            while k < min(len(a), len(b)) and a[k] == b[k]: k += 1
            print("  MISMATCH %-24s len %d vs %d, first at index %d: %r vs %r"
                  % (nm, len(a), len(b), k,
                     a[k] if k < len(a) else None, b[k] if k < len(b) else None))
if only_a:
    print("VCDCMP FAIL: %d signal(s) present in A are missing from B" % len(only_a)); sys.exit(2)
if bad:
    print("VCDCMP FAIL: %d of %d common signals differ" % (bad, len(common))); sys.exit(1)
tot = sum(len(v) for v in ast.values())
print("VCDCMP PASS: all %d common signals identical over %d value changes" % (len(common), tot))
