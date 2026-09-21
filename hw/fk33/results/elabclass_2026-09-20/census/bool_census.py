#!/usr/bin/env python3
"""TRACK ELABCLASS -- the complementary list: which BOOLEAN generic arms has a
synthesiser never been given?

WHY BOOLEANS.  An integer generic mostly changes a SHAPE; a boolean generic
selects which statements ELABORATE, which is the class HDRCOST's defect lives
in.  The integer case is covered separately by the static-index scan, which
looks for the one way an integer CAN change elaboration: a loop bound feeding a
statically folded index.

METHOD, and the false-negative guard.  The dangerous error is calling an arm
COVERED when it is not, so every source of "coverage" here is required to be a
literal in a file the card build reads:

  1. the declared default in rtl/*.vhd  (a generic absent from a map is a
     VALUE, not a blank);
  2. every `NAME => true|false` in any generic map in rtl/*.vhd and
     hw/fk33/rtl/*.vhd.

A generic whose map value is another IDENTIFIER (a pass-through such as
`C_KV_AXI => C_KV_AXI`) contributes NOTHING -- it is recorded as `passthru` and
never as coverage, because resolving it needs the hierarchy and a wrong
resolution in the optimistic direction is exactly the failure to avoid.

`sim/ooc_*.tcl` deliberately contributes NOTHING either.  SHAPEAUDIT already
measured that several of those take their top and generics from argv or env, so
their shape is not knowable from the file; counting them would mark arms
covered on the strength of a script that may never have been run that way.
They are listed separately, as a LEAD.
"""
import os, re, sys, json, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else "tree"

dirs = [os.path.join(ROOT, 'rtl'), os.path.join(ROOT, 'hw', 'fk33', 'rtl')]

def strip_comment(l):
    i = l.find('--')
    return l[:i] if i >= 0 else l

ents = json.load(open(os.path.join(ROOT, '..', 'entities.json')))
booleans = {}   # NAME -> [(entity, default, file)]
for e, gl in ents.items():
    for (nm, ty, df, ln) in gl:
        if ty.strip().lower() == 'boolean':
            booleans.setdefault(nm.upper(), []).append((e, df.strip().lower(), ln))

# every NAME => value in a generic map
seen = collections.defaultdict(lambda: collections.Counter())
passthru = collections.Counter()
maprе = re.compile(r'(\w+)\s*=>\s*([A-Za-z_]\w*|\d+)')
for d in dirs:
    if not os.path.isdir(d):
        continue
    for f in sorted(os.listdir(d)):
        if not f.endswith('.vhd'):
            continue
        for raw in open(os.path.join(d, f), errors='replace'):
            l = strip_comment(raw)
            for m in maprе.finditer(l):
                nm, val = m.group(1).upper(), m.group(2).lower()
                if nm not in booleans:
                    continue
                if val in ('true', 'false'):
                    seen[nm][val] += 1
                else:
                    passthru[nm] += 1

rows = []
for nm in sorted(booleans):
    defaults = set(d for (_e, d, _l) in booleans[nm] if d in ('true', 'false'))
    have = set(seen[nm].keys()) | defaults
    missing = {'true', 'false'} - have
    rows.append((nm, sorted(defaults) or ['(none)'],
                 dict(seen[nm]), passthru[nm], sorted(missing),
                 sorted(set(e for (e, _d, _l) in booleans[nm]))))

print("ELABCLASS_BOOL total_boolean_generic_names=%d" % len(rows))
nomiss = [r for r in rows if not r[4]]
miss = [r for r in rows if r[4]]
print("ELABCLASS_BOOL both_arms_literal_somewhere=%d one_arm_only=%d"
      % (len(nomiss), len(miss)))
print()
print("=== ONE ARM ONLY: the other arm appears as a literal NOWHERE in the")
print("=== synthesisable source, so no synthesiser can have been given it")
print("%-22s %-10s %-24s %-8s %s" % ("generic", "default", "literals seen", "passthru", "entities"))
for (nm, dfl, sn, pt, ms, ents_) in miss:
    print("%-22s %-10s %-24s %-8d %s" %
          (nm, ','.join(dfl), ','.join('%s=%d' % kv for kv in sorted(sn.items())) or '-',
           pt, ','.join(ents_[:4]) + ('...' if len(ents_) > 4 else '')))
print()
print("=== BOTH ARMS appear as a literal somewhere (NOT a claim that both were")
print("=== synthesised -- only that neither is unreachable on its face) ===")
for (nm, dfl, sn, pt, ms, ents_) in nomiss:
    print("%-22s %-10s %-24s %-8d %s" %
          (nm, ','.join(dfl), ','.join('%s=%d' % kv for kv in sorted(sn.items())) or '-',
           pt, ','.join(ents_[:4]) + ('...' if len(ents_) > 4 else '')))
