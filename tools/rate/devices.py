"""tools/rate/devices.py -- the device table.

Hand-written: part strings, operating voltage, board.  Read from Vivado: every
resource count (`refresh`), because a number in this project comes from a tool,
never from typing it."""
import json, os, re
import config

PATH = os.path.join(config.TARGETS, "devices.json")
REQUIRED = ("build_part", "rating_part", "vccint_run", "board")
RES = ("LUT", "FF", "BRAM", "URAM", "DSP")


def validate(d):
    for name, row in d.items():
        miss = [k for k in REQUIRED if k not in row]
        if miss:
            raise SystemExit("devices.json row %s: missing %s" % (name, ", ".join(miss)))
        res = row.get("resources")
        if res is None:
            continue
        if not str(res.get("_source", "")).startswith("vivado "):
            raise SystemExit("devices.json row %s: resources carry no _source 'vivado <ver>'; "
                             "they must come from devices.refresh(), never typed" % name)
        for k in RES:
            if not isinstance(res.get(k), int):
                raise SystemExit("devices.json row %s: resource %s is not an integer" % (name, k))


def load(path=None):
    with open(path or PATH) as f:
        d = json.load(f)
    validate(d)
    return d


def row(name, path=None):
    d = load(path)
    if name not in d:
        raise SystemExit("no device row %r (have %s)" % (name, ", ".join(sorted(d))))
    return d[name]


_PP = re.compile(r"^PARTPROP (\S+) LUT (\d+) FF (\d+) BRAM (\d+) URAM (\d+) DSP (\d+)\s*$", re.M)


def parse_partprops(text):
    if not re.search(r"^PARTPROP_DONE\s*$", text, re.M):
        raise SystemExit("part_props.tcl did not print ^PARTPROP_DONE; the Vivado run did not finish")
    out = {}
    for m in _PP.finditer(text):
        out[m.group(1)] = dict(zip(RES, (int(x) for x in m.groups()[1:])))
    return out


def refresh(path=None, run=None):
    """Fill every row's `resources` from Vivado's own part properties."""
    import vivado
    d = load(path)
    parts = sorted({r["rating_part"] for r in d.values()} | {r["build_part"] for r in d.values()})
    wd = os.path.join(config.WORK_ROOT, "_partprops")
    out = (run or vivado.run_batch)(os.path.join(os.path.dirname(os.path.abspath(__file__)), "part_props.tcl"),
                                    parts, wd, "8G", "rate-partprops")
    got = parse_partprops(out["log"])
    for name, r in d.items():
        p = r["rating_part"]
        if p not in got:
            raise SystemExit("devices.json row %s: Vivado has no part %s" % (name, p))
        r["resources"] = dict(got[p], _source="vivado %s get_parts" % config.VIVADO_VERSION)
    validate(d)
    with open(path or PATH, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write("\n")
    return d
