"""tools/rate/deps.py -- the files a top ACTUALLY reads, from GHDL's own
--elab-order, never a grep (a grep misses packages such as util_pkg)."""
import glob, os, re, subprocess
import config

SKIP = re.compile(r"^\s*library\s+(unisim|beh|xpm)\b", re.I | re.M)   # need Xilinx libs GHDL lacks

def candidate_files(tree):
    out = []
    for d in config.RTL_DIRS:
        for p in sorted(glob.glob(os.path.join(tree, d, "*.vhd"))):
            with open(p, errors="replace") as f:
                if SKIP.search(f.read()):
                    continue
            out.append(os.path.relpath(p, tree))
    return out

def elab_order(tree, top, extra_abs=(), workdir=None):
    os.makedirs(workdir, exist_ok=True)
    files = candidate_files(tree) + list(extra_abs)
    common = ["--std=08", "-frelaxed", "--workdir=%s" % workdir]
    r = subprocess.run(["ghdl", "-i"] + common + files, cwd=tree, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("ghdl -i failed:\n" + r.stderr)
    r = subprocess.run(["ghdl", "--elab-order"] + common + [top], cwd=tree, capture_output=True, text=True)
    if r.returncode != 0 or (not r.stdout.strip() and not extra_abs):
        raise SystemExit("ghdl --elab-order %s failed:\n%s" % (top, r.stderr))
    order = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    # MEASURED 2026-09-25, GHDL 1.0.0: --elab-order OMITS files analysed from an absolute
    # path (the unit is in work-obj08.cf, the file is not listed). The extras are the
    # caller's own files (calibration sources, the generated shell), given in dependency
    # order, so they are appended here in that order.
    return order + [p for p in extra_abs if p not in order]
