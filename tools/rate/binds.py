"""tools/rate/binds.py -- generics as the ELABORATED card has them (Vivado cell properties,
tools/rate/binds.tcl), so a block is rated at the shape it is built at, not at a hand
transcription of llama_top's constant chain."""
import re


def parse(text):
    if not re.search(r"^BIND_DONE\s*$", text, re.M):
        raise SystemExit("binds.tcl did not finish (^BIND_DONE missing)")
    out = {}
    for m in re.finditer(r"^BIND (\S+) (\S+) (.*?)\s*$", text, re.M):
        out.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    return out


def for_row(b, cell, generic_names):
    have = b.get(cell, {})
    missing = [g for g in generic_names if g not in have]
    if missing:
        raise SystemExit("cell %s lacks generics %s in the elaborated design" % (cell, missing))
    return {g: have[g] for g in generic_names}


def vhdl_literal(value, vtype):
    t = vtype.strip().lower()
    if t == "boolean":
        return value.strip().lower()
    if t == "string":
        return '"%s"' % value
    if t == "integer_vector":
        m = re.match(r"^(\d+)'b([01]+)$", value.strip())
        if not m or int(m.group(1)) != len(m.group(2)) or len(m.group(2)) % 32:
            raise SystemExit("binds: integer_vector value %r is not N x 32 bits" % value)
        bits = m.group(2)
        xs = [int(bits[i:i + 32], 2) for i in range(0, len(bits), 32)]
        xs = [x - (1 << 32) if x >= 1 << 31 else x for x in xs]
        return "(0 => %d)" % xs[0] if len(xs) == 1 else "(%s)" % ", ".join(str(x) for x in xs)
    if t == "real":
        r = repr(float(value))
        mant, _, exp = r.partition("e")
        if "." not in mant:
            mant += ".0"
        return mant + ("e" + exp if exp else "")
    if t in ("integer", "natural", "positive") or t.startswith(("integer range", "natural range")):
        return str(int(value))
    raise SystemExit("binds: no literal rule for generic type %r" % vtype)


def generics_for(b, cell, entity, entity_text):
    """Every generic of `entity` as a VHDL literal, read from instance `cell`."""
    import shell
    decl = shell.parse_entity(entity_text, entity)["generics"]
    vals = for_row(b, cell, [n for (n, _, _) in decl])
    return {n: vhdl_literal(vals[n], t) for (n, t, _) in decl}
