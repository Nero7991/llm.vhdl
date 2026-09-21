#!/usr/bin/env python3
"""TRACK ELABCLASS -- scan for the SHAPE of HDRCOST's defect, not for generics.

The defect: a loop whose bound comes from a generic, whose body indexes an
array with an expression in the loop variable that is LARGER than the loop
variable (`2*i`, `i+k`), where a run-time guard makes the out-of-range case
unreachable.  GHDL evaluates only the branch a run takes; Vivado unrolls the
loop and statically evaluates every index.

So the scan is: find `for V in LO to HI loop` / `for V in LO to HI generate`,
then find inside its body any index `NAME(<expr in V>)` where the expression is
not bare `V` and not `V - k`.  Report the file, the loop, the index, the loop
bound's dependence on a generic, and whether a guard (`if`) intervenes.
"""
import os, re, sys, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else "tree"
rtl = os.path.join(ROOT, 'rtl')

forre = re.compile(r'\bfor\s+(\w+)\s+in\s+(.+?)\s+(loop|generate)\b', re.I)
# index expression using the loop var with a scale or positive offset
def risky_index(body_line, v):
    hits = []
    for m in re.finditer(r'(\w+)\s*\(([^()]*\b%s\b[^()]*)\)' % re.escape(v), body_line):
        arr, expr = m.group(1), m.group(2).strip()
        if arr.lower() in ('to_integer', 'to_unsigned', 'to_signed', 'std_logic_vector',
                           'unsigned', 'signed', 'integer', 'natural', 'resize',
                           'shift_left', 'shift_right', 'conv_integer', 'others',
                           'to_stdlogicvector', 'boolean', 'real'):
            continue
        e = expr.replace(' ', '')
        if e == v:
            continue
        # a downto/to slice
        if 'downto' in expr.lower() or re.search(r'\bto\b', expr.lower()):
            kind = 'slice'
        else:
            kind = 'index'
        # classify: grows with i?
        grows = False
        if re.search(r'\d+\s*\*\s*%s\b' % re.escape(v), expr) or \
           re.search(r'\b%s\s*\*\s*\d+' % re.escape(v), expr):
            grows = True
        if re.search(r'\b%s\s*\+' % re.escape(v), expr) or \
           re.search(r'\+\s*%s\b' % re.escape(v), expr):
            grows = True
        if not grows:
            continue
        hits.append((arr, expr, kind))
    return hits

def strip_comment(line):
    i = line.find('--')
    return line[:i] if i >= 0 else line

rows = []
for f in sorted(os.listdir(rtl)):
    if not f.endswith('.vhd'):
        continue
    path = os.path.join(rtl, f)
    lines = [strip_comment(x) for x in open(path, errors='replace').read().split('\n')]
    for i, line in enumerate(lines):
        m = forre.search(line)
        if not m:
            continue
        v, rng, kw = m.group(1), m.group(2), m.group(3).lower()
        # body: until matching end loop / end generate, bounded scan
        depth = 1
        body = []
        guards = 0
        for j in range(i+1, min(len(lines), i+400)):
            l = lines[j]
            if re.search(r'\bfor\s+\w+\s+in\b.*\b(loop|generate)\b', l, re.I):
                depth += 1
            if re.search(r'\bwhile\b.*\bloop\b', l, re.I):
                depth += 1
            if re.search(r'\bend\s+(loop|generate)\b', l, re.I):
                depth -= 1
                if depth == 0:
                    break
            if re.search(r'^\s*if\b|\belsif\b', l, re.I):
                guards += 1
            body.append((j+1, l))
        for (ln, l) in body:
            for (arr, expr, kind) in risky_index(l, v):
                rows.append(dict(file='rtl/'+f, loopline=i+1, var=v, rng=rng.strip(),
                                 kw=kw, idxline=ln, arr=arr, expr=expr, kind=kind,
                                 guards=guards, text=l.strip()))

print("ELABCLASS_SHAPE_HITS %d" % len(rows))
bybound = collections.Counter()
for r in rows:
    bybound[r['file']] += 1
for f, c in bybound.most_common():
    print("  %-40s %d" % (f, c))
print()
for r in rows:
    print("%s:%d loop(%s in %s) -> %s:%d  %s(%s) [%s] guards=%d" %
          (r['file'], r['loopline'], r['var'], r['rng'], r['file'], r['idxline'],
           r['arr'], r['expr'], r['kind'], r['guards']))
    print("      | %s" % r['text'][:150])
