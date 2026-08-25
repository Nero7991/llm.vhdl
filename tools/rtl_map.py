#!/usr/bin/env python3
"""Extract the RTL structure map: entities, their ports, and who instantiates whom.

Written because Vivado's schematic is a GUI-only feature (write_schematic
silently no-ops in -mode batch), and because a flat schematic of a 17,813-cell
elaborated design is not a thing a person can read anyway.  What answers
"what is this design" is the module graph plus port widths, and that is
recoverable from the source.

Emits JSON on stdout.  Deliberately a regex parser, not a VHDL front end:
this reads declarations, and the payoff of a real parser is in expressions.
Any entity it fails on shows up as missing from the graph rather than as a
wrong edge, which is the safe failure direction.
"""
import re, sys, json, os, glob

ENT = re.compile(r'^\s*entity\s+(\w+)\s+is\b', re.I | re.M)
ARCH = re.compile(r'^\s*architecture\s+(\w+)\s+of\s+(\w+)\s+is\b', re.I | re.M)
# component instantiation: label : entity [work.]name  OR  label : name
INST = re.compile(
    r'^\s*(\w+)\s*:\s*(?:entity\s+(?:work\.)?)?(\w+)\s*(?:generic\s+map|port\s+map)',
    re.I | re.M)
PORTLINE = re.compile(
    r'^\s*([\w\s,]+?)\s*:\s*(in|out|inout)\s+(.+?)\s*(?:;|--|$)', re.I)

def strip_comments(s):
    return re.sub(r'--[^\n]*', '', s)

def entity_ports(src, name):
    """Port list of one entity, as (names, dir, type) rows."""
    m = re.search(r'entity\s+' + name + r'\s+is\b(.*?)\bend\b', src,
                  re.I | re.S)
    if not m:
        return []
    body = m.group(1)
    pm = re.search(r'\bport\s*\((.*)', body, re.I | re.S)
    if not pm:
        return []
    # balance parens from the port(
    txt, depth = [], 1
    for ch in pm.group(1):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                break
        txt.append(ch)
    rows = []
    for line in ''.join(txt).split('\n'):
        pl = PORTLINE.match(line)
        if pl:
            names = [n.strip() for n in pl.group(1).split(',') if n.strip()]
            rows.append({'names': names, 'dir': pl.group(2).lower(),
                         'type': pl.group(3).strip().rstrip(';')})
    return rows

def main(paths):
    files, ents, edges = {}, {}, []
    for p in paths:
        raw = open(p, encoding='utf-8', errors='replace').read()
        src = strip_comments(raw)
        files[p] = src
        for e in ENT.findall(src):
            ents[e] = {'file': p, 'ports': entity_ports(src, e),
                       'loc': len(raw.split('\n'))}
    # instantiations, attributed to the architecture's entity
    for p, src in files.items():
        arches = [(m.start(), m.group(2)) for m in ARCH.finditer(src)]
        for m in INST.finditer(src):
            parent = None
            for pos, ent in arches:
                if pos < m.start():
                    parent = ent
            child = m.group(2)
            if parent and child in ents and child != parent:
                edges.append({'from': parent, 'to': child,
                              'label': m.group(1)})
    # dedupe, counting multiplicity
    seen = {}
    for e in edges:
        k = (e['from'], e['to'])
        seen.setdefault(k, []).append(e['label'])
    out_edges = [{'from': a, 'to': b, 'n': len(v), 'labels': v}
                 for (a, b), v in seen.items()]
    json.dump({'entities': ents, 'edges': out_edges}, sys.stdout, indent=1)

if __name__ == '__main__':
    args = sys.argv[1:] or sorted(glob.glob('rtl/*.vhd'))
    main(args)
