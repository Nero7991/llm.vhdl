#!/usr/bin/env python3
"""TRACK ELABCLASS -- the NARROW scan: a STATICALLY EVALUABLE index that grows
faster than the loop variable.

HDRCOST's defect, stated as a shape:

    for i in 0 to <static bound> loop      -- Vivado unrolls; every i is known
      ... arr(<expr in i and constants>)   -- so every index is STATICALLY
                                           -- evaluated, whatever guards it

If the expression mentions any SIGNAL or VARIABLE, the index is run-time and
Vivado builds a mux or a shifter instead of checking a constant -- that is a
different (area) risk and NOT this class.  So the discriminator is:

    every identifier in the index expression is either the loop variable, a
    generic, or a locally declared constant.

`A_DRAIN_WIDE`'s group path is the control for this filter: it indexes with
`(rlane + i - lane0)`, both variables, so it is correctly NOT in this class.
"""
import os, re, sys, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else "tree"
rtl = os.path.join(ROOT, 'rtl')

forre   = re.compile(r'\bfor\s+(\w+)\s+in\s+(.+?)\s+(loop|generate)\b', re.I)
constre = re.compile(r'^\s*constant\s+([\w\s,]+?)\s*:', re.I)
gencl   = re.compile(r'^\s*generic\s*\(', re.I)
gdeclre = re.compile(r'^\s*([\w\s,]+?)\s*:\s*(in\s+)?(positive|natural|integer|boolean|string|real|time)\b', re.I)
funcs = {'to_integer','to_unsigned','to_signed','std_logic_vector','unsigned','signed',
         'integer','natural','resize','shift_left','shift_right','conv_integer','others',
         'boolean','real','minimum','maximum','abs','mod','rem','and','or','not','xor',
         'downto','to','if','then','else','when','loop','generate','sll','srl'}

def strip_comment(line):
    i = line.find('--')
    return line[:i] if i >= 0 else line

def static_names(path):
    """generic names + constant names declared in this file"""
    names = set()
    lines = [strip_comment(x) for x in open(path, errors='replace').read().split('\n')]
    in_gen = False; depth = 0
    for l in lines:
        m = constre.match(l)
        if m:
            for n in m.group(1).split(','):
                n = n.strip()
                if re.match(r'^\w+$', n):
                    names.add(n.upper())
        if gencl.match(l):
            in_gen = True; depth = l.count('(') - l.count(')')
            continue
        if in_gen:
            depth += l.count('(') - l.count(')')
            mm = gdeclre.match(l)
            if mm:
                for n in mm.group(1).split(','):
                    n = n.strip()
                    if re.match(r'^\w+$', n):
                        names.add(n.upper())
            if depth <= 0:
                in_gen = False
    return names

rows = []
for f in sorted(os.listdir(rtl)):
    if not f.endswith('.vhd'):
        continue
    path = os.path.join(rtl, f)
    consts = static_names(path)
    lines = [strip_comment(x) for x in open(path, errors='replace').read().split('\n')]
    # loop stack: (var, range, startline)
    for i, line in enumerate(lines):
        m = forre.search(line)
        if not m:
            continue
        outer = [(m.group(1), m.group(2).strip())]
        # gather enclosing loop vars by scanning backwards is expensive; instead
        # collect ALL loop vars in the file, since a name collision only makes
        # the filter MORE permissive and is reported for reading.
        depth = 1
        body = []
        for j in range(i+1, min(len(lines), i+400)):
            l = lines[j]
            if re.search(r'\bfor\s+\w+\s+in\b.*\b(loop|generate)\b', l, re.I):
                depth += 1
                mm = forre.search(l)
                if mm:
                    outer.append((mm.group(1), mm.group(2).strip()))
            if re.search(r'\bwhile\b.*\bloop\b', l, re.I):
                depth += 1
            if re.search(r'\bend\s+(loop|generate)\b', l, re.I):
                depth -= 1
                if depth == 0:
                    break
            body.append((j+1, l))
        v = m.group(1)
        loopvars = set(x[0].upper() for x in outer)
        for (ln, l) in body:
            for mm in re.finditer(r'(\w+)\s*\(([^()]*)\)', l):
                arr, expr = mm.group(1), mm.group(2).strip()
                if arr.lower() in funcs:
                    continue
                if not re.search(r'\b%s\b' % re.escape(v), expr, re.I):
                    continue
                e = expr.replace(' ', '')
                if e.upper() == v.upper():
                    continue
                # grows with the loop variable?
                grows = bool(re.search(r'\d+\s*\*\s*%s\b' % re.escape(v), expr, re.I) or
                             re.search(r'\b%s\s*\*' % re.escape(v), expr, re.I) or
                             re.search(r'\b%s\s*\+' % re.escape(v), expr, re.I) or
                             re.search(r'\+\s*%s\b' % re.escape(v), expr, re.I))
                if not grows:
                    continue
                ids = set(x.upper() for x in re.findall(r'[A-Za-z_]\w*', expr))
                nonstatic = sorted(ids - loopvars - consts - {x.upper() for x in funcs})
                rows.append(dict(file='rtl/'+f, loop=i+1, var=v,
                                 rng=' / '.join('%s in %s' % o for o in outer),
                                 idxline=ln, arr=arr, expr=expr,
                                 nonstatic=nonstatic, text=l.strip()))

pure = [r for r in rows if not r['nonstatic']]
mixed = [r for r in rows if r['nonstatic']]
print("ELABCLASS_STATIC total_growing=%d purely_static=%d runtime_indexed=%d"
      % (len(rows), len(pure), len(mixed)))
print()
seen = set()
print("=== PURELY STATIC, GROWING INDEX  (HDRCOST's class) ===")
for r in pure:
    k = (r['file'], r['loop'], r['arr'], r['expr'].replace(' ', ''))
    if k in seen:
        continue
    seen.add(k)
    print("%s:%d  loop[%s]  -> :%d  %s(%s)" %
          (r['file'], r['loop'], r['rng'], r['idxline'], r['arr'], r['expr']))
print()
print("=== runtime-indexed (NOT this class; kept as the filter's control) ===")
seen2 = set()
for r in mixed:
    k = (r['file'], r['arr'], r['expr'].replace(' ', ''))
    if k in seen2:
        continue
    seen2.add(k)
    print("%s:%d %s(%s)  nonstatic=%s" % (r['file'], r['idxline'], r['arr'],
                                          r['expr'], ','.join(r['nonstatic'])))
