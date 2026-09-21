#!/usr/bin/env python3
"""TRACK ELABCLASS -- enumerate every generic declared on a synthesisable RTL
entity, and every value any SYNTHESISER has ever been given for it.

Two independent sources of "what has been synthesised":
  1. the card's generated VHDL generic maps (hw/fk33/rtl/*.vhd) -- authoritative
     for the shipping bitstream;
  2. every sim/ooc_*.tcl and sim/ooc_*_run.sh -generic assignment -- the OOC
     harnesses, which are the only OTHER thing that has ever run synth_design.

Prints, per generic: declared default, set of synthesised values, set of values
any bench (sim/tb_*.vhd, sim/*.tcl) reaches, and whether the bench-reachable set
contains anything the synthesised set does not.
"""
import os, re, sys, json, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# ---------------------------------------------------------------- entity scan
ent_re = re.compile(r'^\s*entity\s+(\w+)\s+is\b', re.I)
arch_re = re.compile(r'^\s*architecture\s+\w+\s+of\s+(\w+)\s+is\b', re.I)
gen_start = re.compile(r'^\s*generic\s*\(', re.I)
port_start = re.compile(r'^\s*port\s*\(', re.I)
end_ent = re.compile(r'^\s*end\s+(entity\s+)?(\w+)?\s*;', re.I)

# one generic declaration: NAME[, NAME] : TYPE [:= DEFAULT]
gdecl = re.compile(r'^\s*([\w\s,]+?)\s*:\s*([\w\.\(\)\s\-\+\*/]+?)\s*(?::=\s*(.+?))?\s*;?\s*$')

def strip_comment(line):
    # VHDL comments; no strings with -- in this repo's entity headers
    i = line.find('--')
    return line[:i] if i >= 0 else line

def scan_entities(path):
    """return {entity: [(gname, gtype, gdefault, lineno)]}"""
    out = {}
    lines = open(path, errors='replace').read().split('\n')
    i = 0
    n = len(lines)
    while i < n:
        m = ent_re.match(strip_comment(lines[i]))
        if not m:
            i += 1; continue
        ename = m.group(1)
        i += 1
        gens = []
        depth = 0
        in_gen = False
        while i < n:
            raw = lines[i]
            line = strip_comment(raw)
            if not in_gen:
                if port_start.match(line):
                    break
                if end_ent.match(line):
                    break
                if gen_start.match(line):
                    in_gen = True
                    depth = line.count('(') - line.count(')')
                    rest = line[line.lower().find('generic')+7:]
                    rest = rest[rest.find('(')+1:]
                    if rest.strip():
                        buf = [(rest, i+1)]
                    else:
                        buf = []
                    i += 1
                    continue
                i += 1
                continue
            # inside generic clause
            depth += line.count('(') - line.count(')')
            if depth <= 0:
                # last line: strip trailing ');'
                cut = line.rstrip()
                k = cut.rfind(')')
                if k >= 0:
                    cut = cut[:k]
                if cut.strip():
                    buf.append((cut, i+1))
                in_gen = False
                i += 1
                break
            buf.append((line, i+1))
            i += 1
        # parse buf: split on ';' at depth 0
        if 'buf' in dir():
            pass
        try:
            items = []
            cur = []
            curline = None
            d = 0
            for (txt, ln) in buf:
                if curline is None:
                    curline = ln
                for ch in txt:
                    if ch == '(':
                        d += 1
                    elif ch == ')':
                        d -= 1
                    if ch == ';' and d == 0:
                        items.append((''.join(cur), curline)); cur = []; curline = None
                        continue
                    cur.append(ch)
                cur.append('\n')
            if ''.join(cur).strip():
                items.append((''.join(cur), curline if curline else 0))
            for (txt, ln) in items:
                t = ' '.join(txt.split())
                if not t:
                    continue
                mm = gdecl.match(t)
                if not mm:
                    continue
                names = [x.strip() for x in mm.group(1).split(',') if x.strip()]
                gtype = mm.group(2).strip()
                gdef = (mm.group(3) or '').strip()
                for nm in names:
                    if re.match(r'^\w+$', nm):
                        gens.append((nm, gtype, gdef, ln))
        except NameError:
            pass
        buf = []
        if gens:
            out.setdefault(ename, []).extend(gens)
    return out

rtl_dir = os.path.join(ROOT, 'rtl')
entities = {}
ent_file = {}
for f in sorted(os.listdir(rtl_dir)):
    if not f.endswith('.vhd'):
        continue
    p = os.path.join(rtl_dir, f)
    for e, g in scan_entities(p).items():
        entities.setdefault(e, []).extend(g)
        ent_file[e] = os.path.join('rtl', f)

print("ELABCLASS_ENTCOUNT entities_with_generics=%d" % len(entities))
tot = sum(len(v) for v in entities.values())
print("ELABCLASS_GENCOUNT generic_declarations=%d" % tot)
json.dump({e: [list(x) for x in v] for e, v in entities.items()},
          open(os.path.join(ROOT, '..', 'entities.json'), 'w'), indent=1)
