# Block Ratings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rate every Qwen3.5 building block once per FPGA part (routed fmax, ceiling, structural), re-rate only when its inputs change, and predict the card's tier clocks before a card build.

**Architecture:** A small Python package `tools/rate/` drives Vivado in batch through a generated registered-I/O shell per block. Inputs are two committed tables (`hw/targets/devices.json`, `hw/targets/blocks.json`); outputs are committed JSON records under `hw/targets/ratings/`. A cache key over the GHDL-derived dependency set decides staleness, and two gate rows keep it honest.

**Tech Stack:** Python 3.10 (stdlib + pytest 7.1.2), GHDL 1.0.0 mcode (`--elab-order` only), Vivado 2023.2 batch at `/tools/Xilinx/2023.2/Vivado/2023.2`, systemd-run cgroup caps, bash.

**Spec:** `docs/superpowers/specs/2026-09-25-block-ratings-design.md`

## Global Constraints

- **Subagents get NO hardware access. Ever.** Never `xsdb`, `hw_server`, `vivado ... program`, `hw/fk33/pcieep.sh`, `hw/fk33/jtag.sh`, `hw/fk33/flash.sh`, `hw/fk33/tcl/program.tcl`, `fk33_reload.sh`, or anything opening `/dev/xdma*`. Nothing in this plan needs hardware.
- **ONE Vivado per box.** Every Vivado launch goes through `tools/rate/vivado.py`, which refuses when a Vivado is present (`/proc/PID/exe` contains `unwrapped/lnx64.o/vivado`). Never count processes; gate on presence.
- **Never `pgrep -f` / `pkill -f`.** Identify processes by `/proc/PID/exe` or `/proc/PID/cwd`.
- **Never put a shell variable in a path passed to `rm`.** Delete only by writing the full literal path.
- **No `/tmp` for anything durable.** Rating work directories go under `/mnt/storage/fk33_builds/ratings/<row>/<part>/<key12>/`.
- **Cap every Vivado:** `MemoryHigh` from the caller (workstation default `24G`, BC-250 at most `11G`), read `memory.peak` AND `memory.swap.peak`; a capped peak is the cap, not the size.
- **Rating part = the device row's `rating_part`** (the `-2LV` variant for the VU33P at 0.715 V, `sim/ooc_micro_pnr.tcl:49`). Never `set_operating_conditions -voltage`.
- **Nothing before `route_design` is a rating.** Pre-gate (synthesis depth) is a separate, labelled result.
- **Every lever explicit** in every manifest row; a row that leaves a lever to its default is refused.
- **Resource counts come from Vivado** (`get_parts` properties), never typed.
- **Sentinels are line-anchored** (`^RATE_`): Vivado logs echo the script that writes them.
- **Never `git add -A` / `git add .`**; stage explicit paths. Long messages via `git commit -F <file>`. No Co-Authored-By line. No emojis, no em-dashes.
- **Do not edit `sim/regress.sh` while a gate is running** (bash reads it by byte offset).
- Label every number in records/docs MEASURED, DERIVED or ESTIMATE.

## Review Focus

1. **A block whose port types reference its own generics** (e.g. `std_logic_vector(W-1 downto 0)`): the shell must re-declare those generics with the manifest's values so the port types resolve. Pinned in Task 4 by the `attn_kv_axi` shell analysing under GHDL.
2. **A rating run that ends without `^RATE_DONE route`** (killed by the cap, a Tcl error after success output, unrouted nets): must produce NO record, never a partial one. Pinned in Task 5 (`parse_log` refuses) and Task 7 (unrouted count must be 0).
3. **A lax target makes a rating an underestimate** (Vivado stops optimising once WNS >= 0): the record must say so. Pinned in Task 5: `fmax_is_lower_bound` true when WNS > 0.5 ns.
4. **A dependency changing without the block's own file changing** (e.g. `rtl/util_pkg.vhd`): must make the rating stale. Pinned in Task 3 by the teeth test.
5. **Two rows or two devices writing the same work directory**: keys differ, directories are keyed by `<row>/<part>/<key12>`. Pinned in Task 5.

---

### Task 1: Package skeleton, config, device table filled from Vivado

**Files:**
- Create: `tools/rate/__init__.py` (empty), `tools/rate/config.py`, `tools/rate/devices.py`, `tools/rate/part_props.tcl`, `tools/rate/vivado.py`
- Create: `hw/targets/devices.json`
- Test: `tools/rate/tests/conftest.py`, `tools/rate/tests/test_devices.py`

**Interfaces:**
- Produces: `config.REPO`, `config.VIVADO_ROOT`, `config.VIVADO_VERSION` (`"2023.2"`), `config.TARGETS`, `config.WORK_ROOT` (`/mnt/storage/fk33_builds/ratings`); `devices.load(path=None) -> dict`, `devices.validate(d) -> None` (raises `SystemExit`), `devices.parse_partprops(text) -> dict[str, dict[str,int]]`, `devices.row(name) -> dict`; `vivado.vivado_present() -> bool`, `vivado.run_batch(tcl, args, workdir, mem_high, unit) -> dict` returning `{"log": str, "mem_peak": int|None, "swap_peak": int|None, "rc": int}`.

- [ ] **Step 1: Write the failing tests**

`tools/rate/tests/conftest.py`:
```python
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
```

`tools/rate/tests/test_devices.py`:
```python
import json, pytest
import devices

GOOD = {"vu33p_fk33": {"build_part": "xcvu33p-fsvh2104-2L-e",
                       "rating_part": "xcvu33p-fsvh2104-2LV-e",
                       "vccint_run": 0.715, "board": "fk33", "resources": None}}

def test_validate_accepts_unrefreshed_row():
    devices.validate(GOOD)

def test_validate_refuses_missing_field():
    bad = {"x": {"build_part": "p"}}
    with pytest.raises(SystemExit, match="missing"):
        devices.validate(bad)

def test_validate_refuses_hand_typed_resources():
    bad = json.loads(json.dumps(GOOD))
    bad["vu33p_fk33"]["resources"] = {"LUT": 439680, "FF": 879360, "BRAM": 672, "URAM": 320, "DSP": 2880}
    with pytest.raises(SystemExit, match="_source"):
        devices.validate(bad)

def test_parse_partprops():
    text = ("junk\nPARTPROP xcvu33p-fsvh2104-2LV-e LUT 439680 FF 879360 BRAM 672 URAM 320 DSP 2880\n"
            "PARTPROP_MISSING xcvu99p\nPARTPROP_DONE\n")
    got = devices.parse_partprops(text)
    assert got == {"xcvu33p-fsvh2104-2LV-e": {"LUT": 439680, "FF": 879360, "BRAM": 672, "URAM": 320, "DSP": 2880}}

def test_parse_partprops_refuses_without_done():
    with pytest.raises(SystemExit, match="PARTPROP_DONE"):
        devices.parse_partprops("PARTPROP a LUT 1 FF 1 BRAM 1 URAM 1 DSP 1\n")
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_devices.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'devices'`.

- [ ] **Step 3: Implement**

`tools/rate/config.py`:
```python
"""tools/rate/config.py -- constants shared by the rating flow."""
import os
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
VIVADO_ROOT = "/tools/Xilinx/2023.2/Vivado/2023.2"
VIVADO_VERSION = os.path.basename(VIVADO_ROOT)
TARGETS = os.path.join(REPO, "hw", "targets")
WORK_ROOT = "/mnt/storage/fk33_builds/ratings"     # never /tmp (CLAUDE.md HOUSE STYLE)
RTL_DIRS = ("rtl", os.path.join("hw", "fk33", "rtl"))
```

`tools/rate/devices.py`:
```python
"""tools/rate/devices.py -- the device table. Hand-written: part strings, voltage, board.
Read from Vivado: every resource count (`rate.py devices --refresh`)."""
import json, os, re, sys
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
                             "they must come from `rate.py devices --refresh`, never typed" % name)
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
```

`tools/rate/part_props.tcl`:
```tcl
# tools/rate/part_props.tcl -- print resource counts of each part named in argv.
# Property names verified in Task 1 Step 5 against `report_property [get_parts ...]`.
foreach p $argv {
  set o [get_parts -quiet $p]
  if {[llength $o] != 1} { puts "PARTPROP_MISSING $p"; continue }
  puts [format "PARTPROP %s LUT %s FF %s BRAM %s URAM %s DSP %s" $p \
        [get_property LUT_ELEMENTS $o] [get_property FLIPFLOPS $o] \
        [get_property BLOCK_RAMS $o] [get_property ULTRA_RAMS $o] [get_property DSP $o]]
}
puts "PARTPROP_DONE"
```

`tools/rate/vivado.py`:
```python
"""tools/rate/vivado.py -- the ONLY way the rating flow starts Vivado.
Refuses when a Vivado is already running on this box (presence by /proc/PID/exe,
never a count, never a command line). Runs under a systemd-run cgroup cap and
records memory.peak and memory.swap.peak from inside that cgroup."""
import os, re, shlex, subprocess
import config

MARK = "unwrapped/lnx64.o/vivado"

def vivado_present():
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if MARK in os.readlink("/proc/%s/exe" % p):
                return True
        except OSError:
            continue
    return False

def run_batch(tcl, args, workdir, mem_high="24G", unit="rate-job"):
    if vivado_present():
        raise SystemExit("REFUSED: a Vivado is already running on this box (ONE per box)")
    os.makedirs(workdir, exist_ok=True)
    log = os.path.join(workdir, "vivado.log")
    wrap = os.path.join(workdir, "run.sh")
    argv = " ".join(shlex.quote(a) for a in args)
    # Written to a FILE and run as a file: a `bash -c` string handed to systemd-run has
    # its $vars expanded by systemd (CLAUDE.md, MEASURED 2026-09-21).
    with open(wrap, "w") as f:
        f.write("#!/usr/bin/env bash\n"
                "source %s/settings64.sh\n"
                "cd %s\n"
                "vivado -mode batch -nojournal -log %s -source %s -tclargs %s\n"
                "rc=$?\n"
                "cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)\n"
                "echo \"RATE_MEM peak $(cat $cg/memory.peak) swap_peak $(cat $cg/memory.swap.peak 2>/dev/null || echo NA) rc $rc\" >> %s\n"
                % (config.VIVADO_ROOT, workdir, log, tcl, argv, log))
    os.chmod(wrap, 0o755)
    maxb = "%dG" % (int(mem_high.rstrip("G")) + 2)
    r = subprocess.run(["systemd-run", "--user", "--wait", "--collect", "--unit=%s" % unit,
                        "-p", "MemoryHigh=%s" % mem_high, "-p", "MemoryMax=%s" % maxb, wrap])
    text = open(log).read() if os.path.exists(log) else ""
    m = re.search(r"^RATE_MEM peak (\d+) swap_peak (\S+) rc (\d+)\s*$", text, re.M)
    return {"log": text, "rc": int(m.group(3)) if m else r.returncode,
            "mem_peak": int(m.group(1)) if m else None,
            "swap_peak": int(m.group(2)) if m and m.group(2).isdigit() else None}
```

`hw/targets/devices.json`:
```json
{
  "vu33p_fk33": {
    "build_part": "xcvu33p-fsvh2104-2L-e",
    "rating_part": "xcvu33p-fsvh2104-2LV-e",
    "vccint_run": 0.715,
    "board": "fk33",
    "note": "rating part is the -2LV variant: Vivado reloads -2L as -2LV at reduced VCCINT (sim/ooc_micro_pnr.tcl:49)",
    "resources": null
  }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `python3 -m pytest tools/rate/tests/test_devices.py -q`
Expected: `5 passed`.

- [ ] **Step 5: Verify the Vivado property names, then refresh (one Vivado; check presence first)**

```bash
S=/mnt/storage/fk33_builds/ratings/_partprops; mkdir -p $S
printf 'report_property [get_parts xcvu33p-fsvh2104-2LV-e]\n' > $S/props.tcl
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
(cd $S && vivado -mode batch -nojournal -log $S/props.log -source $S/props.tcl)
grep -E 'LUT_ELEMENTS|FLIPFLOPS|BLOCK_RAMS|ULTRA_RAMS|^DSP ' $S/props.log
```
Expected: five lines naming the five properties. If a name differs, fix `part_props.tcl` to the name Vivado printed.

Then add a `refresh` function to `devices.py`:
```python
def refresh(path=None, run=None):
    import vivado
    d = load(path)
    parts = sorted({r["rating_part"] for r in d.values()} | {r["build_part"] for r in d.values()})
    wd = os.path.join(config.WORK_ROOT, "_partprops")
    out = (run or vivado.run_batch)(os.path.join(os.path.dirname(__file__), "part_props.tcl"),
                                    parts, wd, "8G", "rate-partprops")
    got = parse_partprops(out["log"])
    for name, r in d.items():
        p = r["rating_part"]
        if p not in got:
            raise SystemExit("Vivado has no part %s" % p)
        r["resources"] = dict(got[p], _source="vivado %s get_parts" % config.VIVADO_VERSION)
    validate(d)
    with open(path or PATH, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True); f.write("\n")
    return d
```
And a test using a fake runner:
```python
def test_refresh_writes_sourced_resources(tmp_path):
    p = tmp_path / "devices.json"; p.write_text(json.dumps(GOOD))
    fake = lambda tcl, args, wd, mem, unit: {"log": "PARTPROP xcvu33p-fsvh2104-2LV-e LUT 439680 FF 879360 BRAM 672 URAM 320 DSP 2880\n"
                                                   "PARTPROP xcvu33p-fsvh2104-2L-e LUT 439680 FF 879360 BRAM 672 URAM 320 DSP 2880\nPARTPROP_DONE\n"}
    d = devices.refresh(str(p), fake)
    assert d["vu33p_fk33"]["resources"]["LUT"] == 439680
    assert d["vu33p_fk33"]["resources"]["_source"].startswith("vivado ")
```
Run: `python3 -m pytest tools/rate/tests/test_devices.py -q` -> `6 passed`.

Run the real refresh: `python3 -c "import sys; sys.path.insert(0,'tools/rate'); import devices; print(devices.refresh()['vu33p_fk33']['resources'])"`
Expected (MEASURED anchors, build 18's utilization report): `LUT 439680, FF 879360, BRAM 672, URAM 320, DSP 2880`. Any other value: stop and find out why before continuing.

- [ ] **Step 6: Commit**

```bash
git add tools/rate/__init__.py tools/rate/config.py tools/rate/devices.py tools/rate/part_props.tcl tools/rate/vivado.py tools/rate/tests/conftest.py tools/rate/tests/test_devices.py hw/targets/devices.json
git commit -m "rate: device table with Vivado-sourced resources, capped single-Vivado runner"
```

---

### Task 2: The block manifest and its validation

**Files:**
- Create: `tools/rate/manifest.py`, `hw/targets/blocks.json`, `hw/targets/levers.json`
- Test: `tools/rate/tests/test_manifest.py`

**Interfaces:**
- Consumes: `config.TARGETS`.
- Produces: `manifest.load(path=None) -> dict[str,row]`, `manifest.validate(d, levers) -> None`, `manifest.row(name) -> dict` where a row is `{"top": str, "tier": "stream"|"core"|"calib", "clocks": {port: "*"|[glob,...]}, "generics": {NAME: vhdl_literal_str}, "levers": [NAME,...], "extra_files": [relpath,...], "target_ns": float}`; `manifest.load_levers(path=None) -> dict[NAME, {"top": entity, "silicon": "proven"|"unproven", "evidence": str}]`. A lever is owned by the ENTITY that declares the generic: every row whose `top` is that entity must list it in `levers` and set it in `generics`, so `c_attn` (off) and `c_attn_levers` (on) are both explicit.

- [ ] **Step 1: Write the failing tests**

`tools/rate/tests/test_manifest.py`:
```python
import pytest, manifest

LEV = {"SWEEP_PIPE": {"top": "attn_block", "silicon": "unproven", "evidence": "build 21: 2 hangs in 30"}}

def base():
    return {"c_attn": {"top": "attn_block", "tier": "core", "clocks": {"clk": "*"},
                       "generics": {"SWEEP_PIPE": "false"}, "levers": ["SWEEP_PIPE"],
                       "extra_files": [], "target_ns": 10.0}}

def test_valid():
    manifest.validate(base(), LEV)

def test_lever_not_explicit_is_refused():
    d = base(); del d["c_attn"]["generics"]["SWEEP_PIPE"]
    with pytest.raises(SystemExit, match="explicit"):
        manifest.validate(d, LEV)

def test_lever_unknown_is_refused():
    d = base(); d["c_attn"]["levers"].append("NOPE"); d["c_attn"]["generics"]["NOPE"] = "true"
    with pytest.raises(SystemExit, match="levers.json"):
        manifest.validate(d, LEV)

def test_lever_listed_on_the_wrong_entity_is_refused():
    d = base(); d["other"] = dict(d["c_attn"]); d["other"]["top"] = "x"
    with pytest.raises(SystemExit, match="declared by"):
        manifest.validate(d, LEV)

def test_row_whose_top_owns_a_lever_must_list_it():
    d = base(); d["c_attn"]["levers"] = []
    with pytest.raises(SystemExit, match="must list"):
        manifest.validate(d, LEV)

def test_two_rows_same_top_both_explicit():
    d = base(); d["c_attn_levers"] = dict(d["c_attn"], generics={"SWEEP_PIPE": "true"})
    manifest.validate(d, LEV)

def test_bad_tier_is_refused():
    d = base(); d["c_attn"]["tier"] = "fast"
    with pytest.raises(SystemExit, match="tier"):
        manifest.validate(d, LEV)

def test_no_clock_is_refused():
    d = base(); d["c_attn"]["clocks"] = {}
    with pytest.raises(SystemExit, match="clock"):
        manifest.validate(d, LEV)
```
(A lever belongs to the entity that declares it; a row cannot list another entity's lever, and a row whose top declares one cannot omit it.)

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_manifest.py -q`
Expected: FAIL, `No module named 'manifest'`.

- [ ] **Step 3: Implement**

`tools/rate/manifest.py`:
```python
"""tools/rate/manifest.py -- the block manifest. Every lever EXPLICIT (build 19: a
dropped patch turned four levers on silently)."""
import json, os
import config

PATH = os.path.join(config.TARGETS, "blocks.json")
LEVERS = os.path.join(config.TARGETS, "levers.json")
TIERS = ("stream", "core", "calib")
KEYS = ("top", "tier", "clocks", "generics", "levers", "extra_files", "target_ns")

def validate(d, levers):
    for name, r in d.items():
        miss = [k for k in KEYS if k not in r]
        if miss:
            raise SystemExit("blocks.json %s: missing %s" % (name, ", ".join(miss)))
        if r["tier"] not in TIERS:
            raise SystemExit("blocks.json %s: tier %r not in %s" % (name, r["tier"], TIERS))
        if not r["clocks"]:
            raise SystemExit("blocks.json %s: no clock port named" % name)
        for lv in r["levers"]:
            if lv not in levers:
                raise SystemExit("blocks.json %s: lever %s is not in levers.json" % (name, lv))
            if levers[lv]["top"] != r["top"]:
                raise SystemExit("blocks.json %s: lever %s is declared by %s, not %s"
                                 % (name, lv, levers[lv]["top"], r["top"]))
            if lv not in r["generics"]:
                raise SystemExit("blocks.json %s: lever %s must be set explicitly in generics" % (name, lv))
        for lv, info in levers.items():
            if info["top"] == r["top"] and lv not in r["levers"]:
                raise SystemExit("blocks.json %s: its top %s declares lever %s; the row must list it "
                                 "and set it explicitly" % (name, r["top"], lv))

def load_levers(path=None):
    with open(path or LEVERS) as f:
        return json.load(f)

def load(path=None, levers_path=None):
    with open(path or PATH) as f:
        d = json.load(f)
    validate(d, load_levers(levers_path))
    return d

def row(name, path=None):
    d = load(path)
    if name not in d:
        raise SystemExit("no manifest row %r" % name)
    return d[name]
```

`hw/targets/levers.json` (status as MEASURED on 2026-09-25):
```json
{
  "FAST_POP":    {"top": "matvec_int4_desc_axi", "silicon": "unproven", "evidence": "never on silicon alone; on in build 19 (hangs)"},
  "NWIDE":       {"top": "gdn_state_store",      "silicon": "unproven", "evidence": "never on silicon alone; on in build 19 (hangs)"},
  "SWEEP_PIPE":  {"top": "attn_block",           "silicon": "unproven", "evidence": "build 21 (with SCORE_EARLY): 2 hangs in 30 at pos 32"},
  "SCORE_EARLY": {"top": "attn_block",           "silicon": "unproven", "evidence": "build 21 (with SWEEP_PIPE): 2 hangs in 30 at pos 32"}
}
```

`hw/targets/blocks.json`: start with the calibration row only (real rows arrive in Tasks 7 and 9):
```json
{
  "calib_lut": {"top": "rate_calib_lut", "tier": "calib", "clocks": {"clk": "*"},
                "generics": {"DEPTH": "4", "WIDTH": "64"}, "levers": [],
                "extra_files": ["tools/rate/calib/rate_calib_lut.vhd"], "target_ns": 2.5}
}
```
Owners are MEASURED (`grep -lE '^\s*NWIDE\s*:\s*boolean' rtl/*.vhd`, 2026-09-25): `NWIDE` is declared by `gdn_state_store` (B's state-store movers), `SWEEP_PIPE`/`SCORE_EARLY` by `attn_block`. `FAST_POP` is declared by six entities; it is owned at `matvec_int4_desc_axi`, the one the engine instantiates, which forwards it to the rest.

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m pytest tools/rate/tests/test_manifest.py -q`
Expected: `8 passed`. Then `python3 -c "import sys; sys.path.insert(0,'tools/rate'); import manifest; print(sorted(manifest.load()))"` -> `['calib_lut']`.

- [ ] **Step 5: Commit**

```bash
git add tools/rate/manifest.py tools/rate/tests/test_manifest.py hw/targets/blocks.json hw/targets/levers.json
git commit -m "rate: block manifest with explicit levers and a lever silicon-status table"
```

---

### Task 3: Dependency set (GHDL) and the cache key, with teeth

**Files:**
- Create: `tools/rate/deps.py`, `tools/rate/key.py`
- Test: `tools/rate/tests/test_key.py`

**Interfaces:**
- Consumes: `config.RTL_DIRS`, `config.VIVADO_VERSION`.
- Produces: `deps.candidate_files(tree) -> list[relpath]`; `deps.elab_order(tree, top, extra_abs=(), workdir) -> list[relpath]` (paths relative to `tree`; `extra_abs` files returned as their absolute path); `key.rating_key(tree, dep_files, shell_text, row, rating_part, target_ns, harness_paths) -> hex str`.

- [ ] **Step 1: Write the failing tests**

`tools/rate/tests/test_key.py`:
```python
import os, shutil, subprocess
import pytest, deps, key, config

ROW = {"top": "attn_kv_axi", "generics": {"HEAD_DIM": "256"}, "levers": [], "clocks": {"clk": "*"}}

@pytest.fixture
def tree(tmp_path):
    t = tmp_path / "tree"
    for d in config.RTL_DIRS:
        shutil.copytree(os.path.join(config.REPO, d), t / d)
    return str(t)

def test_elab_order_of_attn_kv_axi(tree, tmp_path):
    got = deps.elab_order(tree, "attn_kv_axi", (), str(tmp_path / "w"))
    assert got == ["rtl/util_pkg.vhd", "rtl/attn_kv_axi.vhd"]    # MEASURED 2026-09-25, ghdl 1.0.0

def k(tree, tmp_path):
    d = deps.elab_order(tree, "attn_kv_axi", (), str(tmp_path / "w"))
    return key.rating_key(tree, d, "shell", ROW, "xcvu33p-fsvh2104-2LV-e", 5.0, [])

def test_key_changes_when_a_dependency_changes(tree, tmp_path):
    a = k(tree, tmp_path)
    with open(os.path.join(tree, "rtl/util_pkg.vhd"), "a") as f:
        f.write("\n-- teeth\n")
    assert k(tree, tmp_path) != a

def test_key_unchanged_when_an_unread_file_changes(tree, tmp_path):
    a = k(tree, tmp_path)
    with open(os.path.join(tree, "rtl/gdn_block.vhd"), "a") as f:     # not read by attn_kv_axi
        f.write("\n-- control\n")
    assert k(tree, tmp_path) == a

def test_key_changes_with_part_target_generics(tree, tmp_path):
    d = deps.elab_order(tree, "attn_kv_axi", (), str(tmp_path / "w"))
    base = key.rating_key(tree, d, "shell", ROW, "p1", 5.0, [])
    assert key.rating_key(tree, d, "shell", ROW, "p2", 5.0, []) != base
    assert key.rating_key(tree, d, "shell", ROW, "p1", 4.0, []) != base
    r2 = dict(ROW, generics={"HEAD_DIM": "128"})
    assert key.rating_key(tree, d, "shell", r2, "p1", 5.0, []) != base
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_key.py -q`
Expected: FAIL, `No module named 'deps'`.

- [ ] **Step 3: Implement**

`tools/rate/deps.py`:
```python
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
    if r.returncode != 0 or not r.stdout.strip():
        raise SystemExit("ghdl --elab-order %s failed:\n%s" % (top, r.stderr))
    return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
```

`tools/rate/key.py`:
```python
"""tools/rate/key.py -- the rating cache key. A block is re-rated ONLY when this changes."""
import hashlib, json, os
import config

def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

def rating_key(tree, dep_files, shell_text, row, rating_part, target_ns, harness_paths):
    h = hashlib.sha256()
    for rel in sorted(dep_files):
        p = rel if os.path.isabs(rel) else os.path.join(tree, rel)
        name = "<extra>" + os.path.basename(rel) if os.path.isabs(rel) else rel
        h.update(("%s\0%s\n" % (name, _sha(p))).encode())
    h.update(("shell\0%s\n" % hashlib.sha256(shell_text.encode()).hexdigest()).encode())
    cfg = {"top": row["top"], "generics": row["generics"], "levers": sorted(row["levers"]),
           "clocks": row["clocks"], "part": rating_part, "target_ns": target_ns,
           "vivado": config.VIVADO_VERSION}
    h.update(json.dumps(cfg, sort_keys=True).encode())
    for p in sorted(harness_paths):
        h.update(("%s\0%s\n" % (os.path.basename(p), _sha(p))).encode())
    return h.hexdigest()
```
Note: shell files are passed to `elab_order` as absolute `extra_abs`, so they appear in the list by basename; their content enters the key through `shell_text` as well.

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m pytest tools/rate/tests/test_key.py -q`
Expected: `4 passed`. If `test_elab_order_of_attn_kv_axi` returns a different list, the RTL changed since 2026-09-25: re-derive the expected list by hand (`ghdl --elab-order`) and update the literal, stating the date in the comment.

- [ ] **Step 5: Commit**

```bash
git add tools/rate/deps.py tools/rate/key.py tools/rate/tests/test_key.py
git commit -m "rate: GHDL-derived dependency set and cache key, with dependency and control teeth"
```

---

### Task 4: The registered-I/O rating shell

**Files:**
- Create: `tools/rate/shell.py`
- Test: `tools/rate/tests/test_shell.py`

**Interfaces:**
- Consumes: `manifest` row dicts (Task 2), `deps.elab_order` (Task 3).
- Produces: `shell.parse_entity(text, name) -> {"context": str, "generics": [(name, type, default)], "ports": [(name, mode, type)]}`; `shell.gen_shell(row, entity_file_text) -> str` (VHDL for entity `rate_shell`); `shell.port_clock(row, port) -> clock_port_name`.

- [ ] **Step 1: Write the failing tests**

`tools/rate/tests/test_shell.py`:
```python
import os, subprocess
import pytest, shell, deps, config

KV = {"top": "attn_kv_axi", "tier": "core", "clocks": {"clk": "*"}, "levers": [], "extra_files": [],
      "target_ns": 5.0,
      "generics": {"HEAD_DIM": "256", "KV_BLOCK": "32", "N_KVH": "4", "LAYERS": "8", "MAXCTX": "65536",
                   "POS_W": "17", "CM_W": "8", "EXP_W": "8", "AXI_DW": "256", "ADDR_W": "33",
                   "MAXB": "16", "MAXOUT": "4", "RBUF": "4"}}

def src(name):
    return open(os.path.join(config.REPO, "rtl", name + ".vhd")).read()

def test_parse_attn_kv_axi():
    e = shell.parse_entity(src("attn_kv_axi"), "attn_kv_axi")
    names = [g[0] for g in e["generics"]]
    assert names[:3] == ["HEAD_DIM", "KV_BLOCK", "N_KVH"]
    pn = [p[0] for p in e["ports"]]
    assert "clk" in pn and "rst" in pn
    assert all(p[1] in ("in", "out") for p in e["ports"])

def test_refuses_inout():
    t = "library ieee; use ieee.std_logic_1164.all;\nentity e is port(clk : in std_logic; b : inout std_logic); end entity;"
    with pytest.raises(SystemExit, match="inout"):
        shell.gen_shell({"top": "e", "clocks": {"clk": "*"}, "generics": {}}, t)

def test_shell_registers_every_port():
    v = shell.gen_shell(KV, src("attn_kv_axi"))
    e = shell.parse_entity(src("attn_kv_axi"), "attn_kv_axi")
    for (n, mode, _) in e["ports"]:
        if n == "clk":
            continue
        assert ("%s_q" % n) in v, n

def test_shell_analyses_and_elaborates_under_ghdl(tmp_path):
    v = shell.gen_shell(KV, src("attn_kv_axi"))
    sp = tmp_path / "rate_shell.vhd"; sp.write_text(v)
    order = deps.elab_order(config.REPO, "rate_shell", (str(sp),), str(tmp_path / "w"))
    assert order[-1] == str(sp)
    common = ["--std=08", "-frelaxed", "--workdir=%s" % (tmp_path / "w")]
    for f in order:
        r = subprocess.run(["ghdl", "-a"] + common + [f], cwd=config.REPO, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
    r = subprocess.run(["ghdl", "-r"] + common + ["rate_shell", "--stop-time=1ns"],
                       cwd=config.REPO, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
```
The generic values in `KV` are the 9B card's (`C_MAXPOS 65536`, `POS_W = clog2(65537) = 17`, `N_KVH 4`, `C_LAY 8` attention layers); Task 7 replaces hand values with values read from the elaborated card.

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_shell.py -q`
Expected: FAIL, `No module named 'shell'`.

- [ ] **Step 3: Implement**

`tools/rate/shell.py`:
```python
"""tools/rate/shell.py -- a registered-I/O wrapper so a block is timed register to
register, as it sits in the card, not against unconstrained OOC pins.
The shell RE-DECLARES the block's generics (defaults = the manifest's values) so port
types that reference them, e.g. std_logic_vector(W-1 downto 0), resolve."""
import fnmatch, re

def _strip(t):
    return re.sub(r"--[^\n]*", "", t)

def _clause(block, kw):
    m = re.search(r"\b%s\s*\(" % kw, block, re.I)
    if not m:
        return ""
    i, depth = m.end(), 1
    while depth:
        c = block[i]
        depth += (c == "(") - (c == ")")
        i += 1
    return block[m.end():i - 1]

def _items(inner):
    out, depth, cur = [], 0, ""
    for c in inner:
        depth += (c == "(") - (c == ")")
        if c == ";" and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur.strip())
    return out

def parse_entity(text, name):
    t = _strip(text)
    m = re.search(r"\bentity\s+%s\s+is(.*?)\bend\s+(entity|%s)\b" % (name, name), t, re.I | re.S)
    if not m:
        raise SystemExit("entity %s not found" % name)
    block = m.group(1)
    context = t[:m.start()].strip()
    gens, ports = [], []
    for it in _items(_clause(block, "generic")):
        names, rest = it.split(":", 1)
        typ, _, dflt = rest.partition(":=")
        for n in names.split(","):
            gens.append((n.strip(), typ.strip(), dflt.strip()))
    for it in _items(_clause(block, "port")):
        names, rest = it.split(":", 1)
        rest = rest.split(":=")[0].strip()
        mode, typ = rest.split(None, 1)
        for n in names.split(","):
            ports.append((n.strip(), mode.lower(), typ.strip()))
    return {"context": context, "generics": gens, "ports": ports}

def port_clock(row, port):
    clocks = row["clocks"]
    for c, globs in clocks.items():
        if globs != "*" and any(fnmatch.fnmatch(port, g) for g in globs):
            return c
    return next(iter(clocks))

def gen_shell(row, entity_text):
    e = parse_entity(entity_text, row["top"])
    bad = [p for p in e["ports"] if p[1] not in ("in", "out")]
    if bad:
        raise SystemExit("rate shell: port %s is %s; inout/buffer ports need an adapter row" % (bad[0][0], bad[0][1]))
    clocks = set(row["clocks"])
    gl = ["    %s : %s := %s" % (n, typ, row["generics"].get(n, d)) for (n, typ, d) in e["generics"]]
    missing = [n for (n, _, d) in e["generics"] if n not in row["generics"] and not d]
    if missing:
        raise SystemExit("rate shell: generic %s has no default and no manifest value" % missing[0])
    pl = ["    %s : %s %s" % (n, m, t) for (n, m, t) in e["ports"]]
    sigs, regs, pmap = [], {c: [] for c in clocks}, []
    for (n, m, t) in e["ports"]:
        if n in clocks:
            pmap.append("%s => %s" % (n, n)); continue
        c = port_clock(row, n)
        if m == "in":
            sigs.append("  signal %s_q : %s;" % (n, t))
            regs[c].append("      %s_q <= %s;" % (n, n))
            pmap.append("%s => %s_q" % (n, n))
        else:
            sigs.append("  signal %s_q : %s;" % (n, t))
            regs[c].append("      %s <= %s_q;" % (n, n))
            pmap.append("%s => %s_q" % (n, n))
    procs = []
    for c, lines in regs.items():
        if lines:
            procs.append("  process(%s) begin\n    if rising_edge(%s) then\n%s\n    end if;\n  end process;"
                         % (c, c, "\n".join(lines)))
    gmap = ", ".join("%s => %s" % (n, n) for (n, _, _) in e["generics"])
    return ("-- GENERATED by tools/rate/shell.py for block %s; DO NOT HAND-EDIT.\n%s\n\n"
            "entity rate_shell is\n  generic(\n%s);\n  port(\n%s);\nend entity;\n\n"
            "architecture rtl of rate_shell is\n%s\nbegin\n"
            "  u_dut : entity work.%s\n    generic map(%s)\n    port map(%s);\n%s\nend architecture;\n"
            % (row["top"], e["context"], ";\n".join(gl), ";\n".join(pl), "\n".join(sigs),
               row["top"], gmap, ",\n      ".join(pmap), "\n".join(procs)))
```
Output ports are driven from the DUT through `<n>_q` and registered into the shell's output port; input ports are registered into `<n>_q` and drive the DUT. If an entity has no generic clause, drop the `generic(...)` block: handle it by emitting the clause only when `gl` is non-empty (add that branch and a test with a generic-free entity).

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m pytest tools/rate/tests/test_shell.py -q`
Expected: `4 passed` (plus the generic-free test). A GHDL failure in the last test names the port or type the parser mishandled; fix the parser, never the RTL.

- [ ] **Step 5: Commit**

```bash
git add tools/rate/shell.py tools/rate/tests/test_shell.py
git commit -m "rate: registered-I/O shell generator; the attn_kv_axi shell analyses and elaborates under GHDL"
```

---

### Task 5: The rating harness, the log parser, and records

**Files:**
- Create: `tools/rate/rate_block.tcl`, `tools/rate/record.py`, `tools/rate/rate.py` (CLI)
- Test: `tools/rate/tests/test_record.py`, fixtures `tools/rate/tests/fixtures/pulse_width.rpt`, `tools/rate/tests/fixtures/rate_ok.log`, `tools/rate/tests/fixtures/rate_killed.log`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: `record.parse_log(text) -> dict` (raises `SystemExit` without `^RATE_DONE`), `record.parse_pulse_width(text) -> float` (ceiling MHz), `record.build(row_name, row, device_name, rating_part, model, key, deps, target_ns, parsed, mem) -> dict`, `record.path(device_name, row_name, model) -> str` (`hw/targets/ratings/<device>/<row>.<model>.json`), `record.fmax_mhz(target_ns, wns) -> float`; CLI `python3 tools/rate/rate.py run <row> --device <d> --model <M> [--mode route|pregate] [--tree PATH] [--mem 24G] [--part-kind rating|build]`.

- [ ] **Step 1: Capture real fixtures**

The pulse-width fixture must be REAL text, not invented. Generate it from any small routed design:
```bash
S=/mnt/storage/fk33_builds/ratings/_fixture; mkdir -p $S
cat > $S/f.tcl <<'EOF'
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/util_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_axi.vhd
synth_design -top attn_kv_axi -part xcvu33p-fsvh2104-2LV-e -mode out_of_context
create_clock -period 5.0 [get_ports clk]
opt_design; place_design; route_design
report_pulse_width -file /mnt/storage/fk33_builds/ratings/_fixture/pulse_width.rpt
EOF
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh; (cd $S && vivado -mode batch -nojournal -source f.tcl -log f.log)
mkdir -p tools/rate/tests/fixtures; head -80 $S/pulse_width.rpt > tools/rate/tests/fixtures/pulse_width.rpt
```
Read the fixture. Note the `Min Period` table's columns and the largest `Required(ns)` value; the test below asserts it (write the value you read, e.g. `1.064` if that is what the file says).

`tools/rate/tests/fixtures/rate_ok.log` (the sentinel lines `rate_block.tcl` prints, as a unit fixture):
```
RATE_SYNTH_LEVELS 7 WNS 0.812
RATE_ROUTE WNS 0.412 WHS 0.031 LEVELS 6 UNROUTED 0 START a/b_reg/C END c/d_reg/D
RATE_UTIL LUT 12345 FF 23456 BRAM 12 URAM 0 DSP 64
RATE_DONE route
```
`tools/rate/tests/fixtures/rate_killed.log`: the same without the last line.

- [ ] **Step 2: Write the failing tests**

`tools/rate/tests/test_record.py`:
```python
import os, pytest, record

F = os.path.join(os.path.dirname(__file__), "fixtures")
def fx(n): return open(os.path.join(F, n)).read()

def test_parse_ok():
    p = record.parse_log(fx("rate_ok.log"))
    assert p["route"]["wns"] == 0.412 and p["route"]["unrouted"] == 0 and p["util"]["DSP"] == 64

def test_killed_run_gives_no_record():
    with pytest.raises(SystemExit, match="RATE_DONE"):
        record.parse_log(fx("rate_killed.log"))

def test_unrouted_is_refused():
    t = fx("rate_ok.log").replace("UNROUTED 0", "UNROUTED 3")
    with pytest.raises(SystemExit, match="unrouted"):
        record.parse_log(t)

def test_sentinel_must_be_line_anchored():
    t = "#  puts \"RATE_DONE route\"\n" + fx("rate_killed.log")
    with pytest.raises(SystemExit):
        record.parse_log(t)

def test_fmax():
    assert abs(record.fmax_mhz(5.0, 0.412) - 1000.0 / 4.588) < 1e-9

def test_lax_target_flagged():
    r = record.build("x", {"tier": "core", "levers": []}, "d", "p", "M", "k", [], 5.0,
                     record.parse_log(fx("rate_ok.log").replace("WNS 0.412", "WNS 1.500")), {})
    assert r["fmax_is_lower_bound"] is True

def test_pulse_width_ceiling():
    mhz = record.parse_pulse_width(fx("pulse_width.rpt"))
    assert mhz == pytest.approx(1000.0 / REQUIRED_NS_READ_FROM_FIXTURE, rel=1e-6)

def test_record_path_distinct_per_device_and_model():
    assert record.path("a", "r", "M1") != record.path("b", "r", "M1") != record.path("a", "r", "M2")
```
Replace `REQUIRED_NS_READ_FROM_FIXTURE` with the literal largest `Required(ns)` value from Step 1.

- [ ] **Step 3: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_record.py -q`
Expected: FAIL, `No module named 'record'`.

- [ ] **Step 4: Implement**

`tools/rate/rate_block.tcl`:
```tcl
# tools/rate/rate_block.tcl -- rate ONE shell: OOC synth, then (mode route) opt/place/phys_opt/route.
#   -tclargs <part> <outdir> <period_ns> <clock,clock> <filelist> <route|pregate>
lassign $argv part outdir period clocks filelist mode
set_param general.maxThreads 8
set fh [open $filelist]; set files [split [string trim [read $fh]] "\n"]; close $fh
foreach f $files { read_vhdl -vhdl2008 $f }
set x [file join $outdir clocks.xdc]; set fh [open $x w]
foreach c [split $clocks ,] { puts $fh "create_clock -name $c -period $period \[get_ports $c\]" }
close $fh
read_xdc -mode out_of_context $x
synth_design -top rate_shell -part $part -mode out_of_context -flatten_hierarchy rebuilt
report_design_analysis -logic_level_distribution -file [file join $outdir levels_synth.rpt]
set wp [get_timing_paths -setup -max_paths 1]
puts "RATE_SYNTH_LEVELS [get_property LOGIC_LEVELS $wp] WNS [get_property SLACK $wp]"
if {$mode eq "pregate"} { puts "RATE_DONE pregate"; exit 0 }
opt_design; place_design; phys_opt_design; route_design
report_timing_summary -max_paths 20 -file [file join $outdir timing_routed.rpt]
report_utilization -file [file join $outdir util_routed.rpt]
report_pulse_width -file [file join $outdir pulse_width.rpt]
report_design_analysis -logic_level_distribution -file [file join $outdir levels_routed.rpt]
set wp [get_timing_paths -setup -max_paths 1]
set wh [get_timing_paths -hold -max_paths 1]
set unr [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED || ROUTE_STATUS == CONFLICTS}]]
puts "RATE_ROUTE WNS [get_property SLACK $wp] WHS [get_property SLACK $wh] LEVELS [get_property LOGIC_LEVELS $wp] UNROUTED $unr START [get_property STARTPOINT_PIN $wp] END [get_property ENDPOINT_PIN $wp]"
set u [report_utilization -return_string]
proc used {u row} { if {[regexp "\\| $row +\\| +(\[0-9.\]+)" $u -> v]} { return $v }; return -1 }
puts "RATE_UTIL LUT [used $u {CLB LUTs}] FF [used $u {CLB Registers}] BRAM [used $u {Block RAM Tile}] URAM [used $u URAM] DSP [used $u DSPs]"
write_checkpoint -force [file join $outdir routed.dcp]
puts "RATE_DONE route"
```
Before trusting `RATE_UTIL`, compare it once against `util_routed.rpt` by eye for the first real row (Task 7); the regexp reads the "Used" column.

`tools/rate/record.py`:
```python
"""tools/rate/record.py -- parse a rating log and build its committed record.
No ^RATE_DONE, no record: a killed or failed run must never look like a rating."""
import json, os, re
import config

def _need(pat, text, what):
    m = re.search(pat, text, re.M)
    if not m:
        raise SystemExit("rating log has no %s line" % what)
    return m

def parse_log(text):
    _need(r"^RATE_DONE (route|pregate)\s*$", text, "^RATE_DONE")
    out = {}
    m = _need(r"^RATE_SYNTH_LEVELS (\d+) WNS (-?[\d.]+)\s*$", text, "^RATE_SYNTH_LEVELS")
    out["synth"] = {"levels": int(m.group(1)), "wns": float(m.group(2))}
    if re.search(r"^RATE_DONE route\s*$", text, re.M):
        m = _need(r"^RATE_ROUTE WNS (-?[\d.]+) WHS (-?[\d.]+) LEVELS (\d+) UNROUTED (\d+) START (\S+) END (\S+)\s*$",
                  text, "^RATE_ROUTE")
        out["route"] = {"wns": float(m.group(1)), "whs": float(m.group(2)), "levels": int(m.group(3)),
                        "unrouted": int(m.group(4)), "start": m.group(5), "end": m.group(6)}
        if out["route"]["unrouted"]:
            raise SystemExit("rating has %d unrouted nets: not a rating" % out["route"]["unrouted"])
        m = _need(r"^RATE_UTIL LUT (\S+) FF (\S+) BRAM (\S+) URAM (\S+) DSP (\S+)\s*$", text, "^RATE_UTIL")
        out["util"] = dict(zip(("LUT", "FF", "BRAM", "URAM", "DSP"), (float(x) for x in m.groups())))
        out["util"] = {k: int(v) if v == int(v) else v for k, v in out["util"].items()}
    return out

def parse_pulse_width(text):
    req = [float(m.group(1)) for m in re.finditer(r"^Min Period\s+\S+\s+\S+\s+\S+\s+([\d.]+)\s", text, re.M)]
    if not req:
        raise SystemExit("pulse-width report has no Min Period rows")
    return 1000.0 / max(req)

def fmax_mhz(target_ns, wns):
    return 1000.0 / (target_ns - wns)

def path(device, row, model):
    return os.path.join(config.TARGETS, "ratings", device, "%s.%s.json" % (row, model))

def build(row_name, row, device, rating_part, model, key, deps, target_ns, parsed, mem, ceiling=None):
    r = {"row": row_name, "device": device, "part": rating_part, "model": model, "key": key,
         "deps": sorted(deps), "target_ns": target_ns, "tier": row["tier"], "levers": row["levers"],
         "synth": parsed["synth"], "vivado": config.VIVADO_VERSION, "mem": mem,
         "evidence": "MEASURED, one draw; below the routed noise floor (0.4-0.75 ns) differences are not results"}
    if "route" in parsed:
        r["route"], r["util"] = parsed["route"], parsed["util"]
        r["achieved_mhz"] = fmax_mhz(target_ns, parsed["route"]["wns"])
        r["fmax_is_lower_bound"] = parsed["route"]["wns"] > 0.5    # lax target: Vivado stopped early
        r["ceiling_mhz"] = ceiling
    return r
```
The `Min Period` regexp must match the fixture's real column layout: adjust the number of `\S+` fields to the columns you read in Step 1 (Check Type, Corner, Lib Pin, Reference Pin come before `Required(ns)` in 2023.2; if not, follow the file).

`tools/rate/rate.py` (the CLI; `run` only in this task, `status`/`preflight` arrive later):
```python
#!/usr/bin/env python3
"""tools/rate/rate.py -- rate a manifest row on a device.  See docs/superpowers/specs/2026-09-25-block-ratings-design.md"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config, devices, manifest, deps, key, shell, record, vivado

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = [os.path.join(HERE, "rate_block.tcl"), os.path.join(HERE, "shell.py")]

def entity_text(tree, row):
    cands = [os.path.join(tree, p) for p in row["extra_files"]] + \
            [os.path.join(tree, d, row["top"] + ".vhd") for d in config.RTL_DIRS]
    for p in cands:
        if os.path.exists(p) and ("entity %s is" % row["top"]) in open(p).read().lower():
            return open(p).read()
    raise SystemExit("cannot find the file declaring entity %s" % row["top"])

def cmd_run(a):
    row = manifest.row(a.row)
    dev = devices.row(a.device)
    part = dev["rating_part"] if a.part_kind == "rating" else dev["build_part"]
    tree = os.path.abspath(a.tree)
    text = shell.gen_shell(row, entity_text(tree, row))
    probe = os.path.join(config.WORK_ROOT, a.row, part, "_probe")
    os.makedirs(probe, exist_ok=True)
    sp0 = os.path.join(probe, "rate_shell.vhd"); open(sp0, "w").write(text)
    extra = [os.path.join(tree, p) for p in row["extra_files"]]
    order = deps.elab_order(tree, "rate_shell", extra + [sp0], os.path.join(probe, "ghdl"))
    k = key.rating_key(tree, [p for p in order if p != sp0], text, row, part, row["target_ns"], HARNESS)
    wd = os.path.join(config.WORK_ROOT, a.row, part, k[:12])
    os.makedirs(wd, exist_ok=True)
    sp = os.path.join(wd, "rate_shell.vhd"); open(sp, "w").write(text)
    fl = os.path.join(wd, "files.txt")
    open(fl, "w").write("\n".join((p if os.path.isabs(p) else os.path.join(tree, p)).replace(sp0, sp)
                                  for p in order) + "\n")
    out = vivado.run_batch(HARNESS[0], [part, wd, str(row["target_ns"]), ",".join(row["clocks"]), fl, a.mode],
                           wd, a.mem, "rate-%s" % a.row)
    parsed = record.parse_log(out["log"])
    ceiling = None
    if a.mode == "route":
        ceiling = record.parse_pulse_width(open(os.path.join(wd, "pulse_width.rpt")).read())
    rec = record.build(a.row, row, a.device, part, a.model, k, [p for p in order if p != sp0],
                       row["target_ns"], parsed, {"peak": out["mem_peak"], "swap_peak": out["swap_peak"],
                                                  "cap": a.mem}, ceiling)
    if a.mode == "pregate":
        print("RATE_PREGATE %s %s levels %d" % (a.row, part, parsed["synth"]["levels"]))
        return
    dst = record.path(a.device if a.part_kind == "rating" else a.device + "_build", a.row, a.model)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    json.dump(rec, open(dst, "w"), indent=2, sort_keys=True)
    print("RATE_RECORD %s achieved %.1f MHz ceiling %.1f MHz -> %s" % (a.row, rec["achieved_mhz"], ceiling, dst))

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("row"); r.add_argument("--device", required=True); r.add_argument("--model", required=True)
    r.add_argument("--mode", choices=("route", "pregate"), default="route")
    r.add_argument("--tree", default=config.REPO); r.add_argument("--mem", default="24G")
    r.add_argument("--part-kind", choices=("rating", "build"), default="rating")
    a = ap.parse_args()
    {"run": cmd_run}[a.cmd](a)

if __name__ == "__main__":
    main()
```
`--model` is recorded in the record and the path; the generics themselves come from the manifest row (Task 7 ties them to the model). `--part-kind build` rates on the sign-off part (e.g. `-2L` at 0.85 V), used by the voltage teeth check and the 200 MHz anchor.

- [ ] **Step 5: Run to verify the unit tests pass**

Run: `python3 -m pytest tools/rate/tests -q`
Expected: all pass (Tasks 1-5).

- [ ] **Step 6: Commit**

```bash
git add tools/rate/rate_block.tcl tools/rate/record.py tools/rate/rate.py tools/rate/tests/test_record.py tools/rate/tests/fixtures/pulse_width.rpt tools/rate/tests/fixtures/rate_ok.log tools/rate/tests/fixtures/rate_killed.log
git commit -m "rate: OOC route harness, sentinel-gated log parser, records keyed per device/row/model"
```

---

### Task 6: Calibration micro-benchmark and the structural predictor

**Files:**
- Create: `tools/rate/calib/rate_calib_lut.vhd`, `tools/rate/calib.py`, `tools/rate/predict.py`
- Create (generated, committed): `hw/targets/calib/<device>.json`
- Modify: `hw/targets/blocks.json` (calib rows at DEPTH 1..12)
- Test: `tools/rate/tests/test_predict.py`

**Interfaces:**
- Consumes: `rate.py run` (Task 5).
- Produces: `predict.load_table(device) -> {"lut": {depth:int -> mhz:float}}`, `predict.structural_mhz(levels, table) -> (mhz, "measured"|"beyond-calibration")`, `predict.max_levels(mhz, table) -> int`.

- [ ] **Step 1: The calibration block**

`tools/rate/calib/rate_calib_lut.vhd`:
```vhdl
-- tools/rate/calib/rate_calib_lut.vhd -- DEPTH levels of LUT6 between registers, WIDTH lanes.
-- dont_touch on every stage keeps one LUT per level; the rating shell supplies the registers.
library ieee; use ieee.std_logic_1164.all;
entity rate_calib_lut is
  generic(DEPTH : positive := 4; WIDTH : positive := 64);
  port(clk : in std_logic;
       d   : in  std_logic_vector(WIDTH*6-1 downto 0);
       q   : out std_logic_vector(WIDTH-1 downto 0));
end entity;
architecture rtl of rate_calib_lut is
  type stage_t is array (0 to DEPTH) of std_logic_vector(WIDTH-1 downto 0);
  signal s : stage_t;
  attribute dont_touch : string;
  attribute dont_touch of s : signal is "true";
begin
  lanes : for l in 0 to WIDTH-1 generate
    s(0)(l) <= d(l*6) xor d(l*6+1) xor d(l*6+2) xor d(l*6+3) xor d(l*6+4) xor d(l*6+5);
    levels : for k in 1 to DEPTH-1 generate
      s(k)(l) <= s(k-1)(l) xor d((l*6 + k) mod (WIDTH*6)) xor d((l*6 + 2*k + 1) mod (WIDTH*6))
                 xor d((l*6 + 3*k + 2) mod (WIDTH*6)) xor d((l*6 + 5*k + 3) mod (WIDTH*6))
                 xor d((l*6 + 7*k + 4) mod (WIDTH*6));
    end generate;
    q(l) <= s(DEPTH-1)(l);
  end generate;
end architecture;
```
The `clk` port exists only so the shell has a clock; the entity itself is combinational.

- [ ] **Step 2: Write the failing predictor tests**

`tools/rate/tests/test_predict.py`:
```python
import pytest, predict

T = {"lut": {1: 800.0, 2: 650.0, 4: 480.0, 8: 300.0, 12: 220.0}}

def test_measured_point():
    assert predict.structural_mhz(4, T) == (480.0, "measured")

def test_interpolates_in_period():
    mhz, how = predict.structural_mhz(6, T)
    assert how == "measured"
    assert mhz == pytest.approx(1000.0 / ((1000/480 + 1000/300) / 2))

def test_beyond_calibration_is_labelled():
    assert predict.structural_mhz(15, T)[1] == "beyond-calibration"

def test_max_levels():
    assert predict.max_levels(300.0, T) == 8
    assert predict.max_levels(1000.0, T) == 0

def test_table_must_be_monotone():
    with pytest.raises(SystemExit, match="monotone"):
        predict.check({"lut": {1: 500.0, 2: 600.0}})
```

- [ ] **Step 3: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_predict.py -q`
Expected: FAIL, `No module named 'predict'`.

- [ ] **Step 4: Implement**

`tools/rate/predict.py`:
```python
"""tools/rate/predict.py -- structural fmax from a MEASURED per-part depth table.
Interpolation is in PERIOD (each level adds delay); nothing is extrapolated silently."""
import json, os
import config

def check(t):
    ds = sorted(t["lut"])
    for a, b in zip(ds, ds[1:]):
        if t["lut"][b] >= t["lut"][a]:
            raise SystemExit("calibration table is not monotone at depth %d -> %d" % (a, b))

def load_table(device):
    with open(os.path.join(config.TARGETS, "calib", "%s.json" % device)) as f:
        t = json.load(f)
    t["lut"] = {int(k): float(v) for k, v in t["lut"].items()}
    check(t)
    return t

def structural_mhz(levels, t):
    lut = t["lut"]; ds = sorted(lut)
    if levels in lut:
        return lut[levels], "measured"
    if levels < ds[0] or levels > ds[-1]:
        near = ds[0] if levels < ds[0] else ds[-1]
        return lut[near], "beyond-calibration"
    lo = max(d for d in ds if d < levels); hi = min(d for d in ds if d > levels)
    p = 1000/lut[lo] + (1000/lut[hi] - 1000/lut[lo]) * (levels - lo) / (hi - lo)
    return 1000.0 / p, "measured"

def max_levels(mhz, t):
    ok = [d for d, f in t["lut"].items() if f >= mhz]
    return max(ok) if ok else 0
```

`tools/rate/calib.py`:
```python
#!/usr/bin/env python3
"""Rate calib_lut at DEPTH 1,2,3,4,6,8,10,12 on a device and write hw/targets/calib/<device>.json."""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config, record

DEPTHS = (1, 2, 3, 4, 6, 8, 10, 12)

def main(device, model="CALIB"):
    lut = {}
    for d in DEPTHS:
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "rate.py"), "run",
                            "calib_lut_d%d" % d, "--device", device, "--model", model], check=True)
        rec = json.load(open(record.path(device, "calib_lut_d%d" % d, model)))
        if rec["fmax_is_lower_bound"]:
            raise SystemExit("depth %d met a lax target (WNS %.3f): tighten its target_ns and re-run"
                             % (d, rec["route"]["wns"]))
        lut[d] = rec["achieved_mhz"]
    out = {"device": device, "lut": lut, "evidence": "MEASURED, routed, one draw per depth"}
    os.makedirs(os.path.join(config.TARGETS, "calib"), exist_ok=True)
    json.dump(out, open(os.path.join(config.TARGETS, "calib", "%s.json" % device), "w"), indent=2, sort_keys=True)
    print("CALIB_DONE", device, lut)

if __name__ == "__main__":
    main(sys.argv[1])
```

In `hw/targets/blocks.json` replace `calib_lut` with eight rows `calib_lut_d1` .. `calib_lut_d12` (DEPTH = 1,2,3,4,6,8,10,12), each `"target_ns"` set tight: `1.0` for d1-d2, `1.5` for d3-d4, `2.5` for d6-d8, `3.5` for d10-d12 (ESTIMATE; `calib.py` refuses a lax result, so a wrong guess costs a re-run, not a wrong table).

- [ ] **Step 5: Run the unit tests, then the real calibration (one Vivado at a time, ~8 short runs)**

Run: `python3 -m pytest tools/rate/tests/test_predict.py -q` -> `5 passed`.
Run: `python3 tools/rate/calib.py vu33p_fk33`
Expected: `CALIB_DONE vu33p_fk33 {1: ..., 12: ...}`, monotone (`predict.check` passes on load). Then the voltage teeth check: rate `calib_lut_d4` with `--part-kind build` (the `-2L` part):
`python3 tools/rate/rate.py run calib_lut_d4 --device vu33p_fk33 --model CALIB --part-kind build`
Expected: its achieved MHz is HIGHER than the `-2LV` value (the 2026-08-24 measurement: -22.9% mean derate at 0.72 V). Equal values mean the variant did nothing: stop.

- [ ] **Step 6: Commit**

```bash
git add tools/rate/calib/rate_calib_lut.vhd tools/rate/calib.py tools/rate/predict.py tools/rate/tests/test_predict.py hw/targets/blocks.json hw/targets/calib/vu33p_fk33.json hw/targets/ratings/vu33p_fk33/calib_lut_d*.CALIB.json hw/targets/ratings/vu33p_fk33_build/calib_lut_d4.CALIB.json
git commit -m "rate: per-part LUT-depth calibration (MEASURED, routed) and the structural predictor; -2LV vs -2L teeth"
```

---

### Task 7: Generics from the elaborated card, and the first real rows with anchors

**Files:**
- Create: `tools/rate/binds.tcl`, `tools/rate/binds.py`
- Create (generated, committed): `hw/targets/binds/QWEN35_9B.json`
- Modify: `hw/targets/blocks.json` (rows `a_engine`, `c_kv`)
- Test: `tools/rate/tests/test_binds.py`

**Interfaces:**
- Produces: `binds.parse(text) -> dict[cell_path, dict[generic, value_str]]`; `binds.for_row(binds, cell_path) -> dict[generic, str]`.

- [ ] **Step 1: Prove the elaborated design exposes generics as cell properties (teeth first)**

`tools/rate/binds.tcl`:
```tcl
# Elaborate the card top (RTL only, no synthesis) and print every generic of the named cells.
#   -tclargs <part> <filelist> <top> <cell> [<cell> ...]
lassign $argv part filelist top
set cells [lrange $argv 3 end]
set fh [open $filelist]; foreach f [split [string trim [read $fh]] "\n"] { read_vhdl -vhdl2008 $f }; close $fh
synth_design -rtl -top $top -part $part
foreach c $cells {
  set o [get_cells -quiet $c]
  if {[llength $o] != 1} { puts "BIND_MISSING $c"; continue }
  foreach p [list_property $o] { puts "BIND $c $p [get_property $p $o]" }
}
puts "BIND_DONE"
```
Run it on `llama_top` (9B) for cells `u_kv u_attn` using the file list `deps.elab_order(REPO, "llama_top", ...)` writes (paths absolute), through `vivado.run_batch` with `--mem 24G`. Read the output.
Expected: `BIND u_kv HEAD_DIM 256` and `BIND u_kv KV_BLOCK 32` (the 9B values, `rtl/llama_top.vhd:6660` and C_KV_BLOCK). **If generics do not appear as properties, STOP**: record that in the plan's execution notes and fall back to hand values labelled UNVERIFIED in the manifest; do not guess another mechanism.

- [ ] **Step 2: Write the parser test against the real output**

Save the `BIND` lines as `tools/rate/tests/fixtures/binds_9b.txt`, then `tools/rate/tests/test_binds.py`:
```python
import os, binds
F = os.path.join(os.path.dirname(__file__), "fixtures", "binds_9b.txt")

def test_kv_generics():
    b = binds.parse(open(F).read())
    assert b["u_kv"]["HEAD_DIM"] == "256" and b["u_kv"]["KV_BLOCK"] == "32"

def test_missing_done_refused():
    import pytest
    with pytest.raises(SystemExit):
        binds.parse("BIND u_kv HEAD_DIM 256\n")
```

`tools/rate/binds.py`:
```python
"""tools/rate/binds.py -- generics as the ELABORATED design has them (Vivado cell properties),
so a block is rated at the shape it is built at, not at a hand transcription."""
import re

def parse(text):
    if not re.search(r"^BIND_DONE\s*$", text, re.M):
        raise SystemExit("binds.tcl did not finish (^BIND_DONE missing)")
    out = {}
    for m in re.finditer(r"^BIND (\S+) (\S+) (.*?)\s*$", text, re.M):
        out.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    return out

def for_row(b, cell, generic_names):
    missing = [g for g in generic_names if g not in b.get(cell, {})]
    if missing:
        raise SystemExit("cell %s lacks generics %s in the elaborated design" % (cell, missing))
    return {g: b[cell][g] for g in generic_names}
```
Run: `python3 -m pytest tools/rate/tests/test_binds.py -q` -> `2 passed`. Write `hw/targets/binds/QWEN35_9B.json` from `binds.parse` of the real run (json.dump, sorted keys).

- [ ] **Step 3: Add the rows, generics from the binds**

In `hw/targets/blocks.json` add `c_kv` (top `attn_kv_axi`, tier `core`, clocks `{"clk": "*"}`, levers `[]`, target_ns `5.0`) with `generics` = `binds.for_row(b, "u_kv", <attn_kv_axi generic names>)`, formatted as VHDL literals (integers as digits, booleans `true`/`false`). For `a_engine` (top `matvec_int4_desc_axi`, tier `stream`, clocks `{"s_axi_aclk": ["s_axi_*"], "m_aclk": "*"}`, levers `["FAST_POP"]`, `FAST_POP` explicitly `"false"`, target_ns `4.0`) take the engine's generics from `hw/fk33/rtl/fk33_engine.vhd`'s instance (it is outside `llama_top`); run `binds.tcl` on `fk33_engine` for its `matvec_int4_desc_axi` cell.

- [ ] **Step 4: Rate them and check the anchors**

```bash
python3 tools/rate/rate.py run c_kv --device vu33p_fk33 --model QWEN35_9B
python3 tools/rate/rate.py run a_engine --device vu33p_fk33 --model QWEN35_9B --part-kind build
python3 tools/rate/rate.py run a_engine --device vu33p_fk33 --model QWEN35_9B
```
Anchors (spec section 5):
- `a_engine` on the build part (`-2L`, 0.85 V): achieved **>= 200 MHz** (the engine-only card build closed at 200 MHz). Lower: stop and explain before any other row.
- `c_kv`: compare against the 2026-09-05 implemented C mover (155.3 MHz at 0.85 V). Before comparing, confirm the 2026-09-05 run's top (`sim/ooc_cattnadapt.tcl`, `rtl/ooc_cattnadapt_top.vhd`) contains `attn_kv_axi` at the same generics; if it is a different top, add a row for that top and compare that row instead.
- Cross-check `RATE_UTIL` against `util_routed.rpt` for `c_kv` by eye (Task 5 note).

- [ ] **Step 5: Commit**

```bash
git add tools/rate/binds.tcl tools/rate/binds.py tools/rate/tests/test_binds.py tools/rate/tests/fixtures/binds_9b.txt hw/targets/binds/QWEN35_9B.json hw/targets/blocks.json hw/targets/ratings/vu33p_fk33/a_engine.QWEN35_9B.json hw/targets/ratings/vu33p_fk33/c_kv.QWEN35_9B.json hw/targets/ratings/vu33p_fk33_build/a_engine.QWEN35_9B.json
git commit -m "rate: generics from the elaborated card; first rows a_engine and c_kv rated, anchors checked"
```

---

### Task 8: Staleness status and the two gate rows

**Files:**
- Modify: `tools/rate/rate.py` (add `status` subcommand)
- Modify: `sim/regress.sh` (rows `ratetests`, `ratestale`)
- Test: `tools/rate/tests/test_status.py`

**Interfaces:**
- Produces: `rate.py status [--check]` printing `^RATESTATUS <device> <row> <model> (FRESH|STALE|UNRATED)` lines and `^RATESTALE_SUMMARY fresh N stale N unrated N`; exit 1 under `--check` iff any STALE.

- [ ] **Step 1: Write the failing test**

`tools/rate/tests/test_status.py`:
```python
import json, os, subprocess, sys
RATE = os.path.join(os.path.dirname(__file__), "..", "rate.py")

def test_status_check_runs_and_summarises():
    r = subprocess.run([sys.executable, RATE, "status"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert any(l.startswith("RATESTALE_SUMMARY ") for l in r.stdout.splitlines())
```
And the teeth, as a manual step (not a unit test, because it edits the tree): Step 4.

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m pytest tools/rate/tests/test_status.py -q` -> FAIL (`invalid choice: 'status'`).

- [ ] **Step 3: Implement `status`**

Add to `rate.py`:
```python
def current_key(row_name, row, dev, part, tree=config.REPO):
    text = shell.gen_shell(row, entity_text(tree, row))
    probe = os.path.join(config.WORK_ROOT, row_name, part, "_probe")
    os.makedirs(probe, exist_ok=True)
    sp0 = os.path.join(probe, "rate_shell.vhd"); open(sp0, "w").write(text)
    extra = [os.path.join(tree, p) for p in row["extra_files"]]
    order = deps.elab_order(tree, "rate_shell", extra + [sp0], os.path.join(probe, "ghdl"))
    return key.rating_key(tree, [p for p in order if p != sp0], text, row, part, row["target_ns"], HARNESS)

def cmd_status(a):
    import glob
    rows = manifest.load(); devs = devices.load()
    n = {"FRESH": 0, "STALE": 0, "UNRATED": 0}
    for dname, dev in sorted(devs.items()):
        for rname, row in sorted(rows.items()):
            recs = glob.glob(record.path(dname, rname, "*"))
            if not recs:
                n["UNRATED"] += 1; print("RATESTATUS %s %s - UNRATED" % (dname, rname)); continue
            k = current_key(rname, row, dev, dev["rating_part"])
            for rp in sorted(recs):
                rec = json.load(open(rp))
                st = "FRESH" if rec["key"] == k else "STALE"
                n[st] += 1
                print("RATESTATUS %s %s %s %s" % (dname, rname, rec["model"], st))
    print("RATESTALE_SUMMARY fresh %d stale %d unrated %d" % (n["FRESH"], n["STALE"], n["UNRATED"]))
    if a.check and n["STALE"]:
        sys.exit(1)
```
and register `st = sub.add_parser("status"); st.add_argument("--check", action="store_true")` with `"status": cmd_status` in the dispatch dict. (Records under `<device>_build/` are the sign-off-part teeth ratings and are not status-checked; they are evidence, not current ratings.)

- [ ] **Step 4: Teeth, by hand, on a copy of one dependency**

```bash
python3 tools/rate/rate.py status | grep c_kv          # FRESH
printf '\n-- ratestale teeth\n' >> rtl/util_pkg.vhd
python3 tools/rate/rate.py status --check; echo rc=$?  # c_kv STALE, rc=1
git checkout -- rtl/util_pkg.vhd
python3 tools/rate/rate.py status --check; echo rc=$?  # FRESH, rc=0
```
Expected exactly as commented. If the edit does not make it STALE, the key does not see the dependency: go back to Task 3.

- [ ] **Step 5: Add the gate rows (no gate may be running while you edit `sim/regress.sh`)**

Next to the `printf 'cardtop\tsim\tRUN...` line add:
```bash
# sim:ratetests -- the rating flow's own unit tests (tools/rate/tests). No Vivado.
printf 'ratetests\tsim\tRUN\t-\t-\t-\t-\n' >> "$PLAN"
# sim:ratestale -- a committed rating whose cache key no longer matches the tree is RED.
# UNRATED rows are reported, not red, so the gate is usable during rollout; preflight refuses them.
printf 'ratestale\tsim\tRUN\t-\t-\t-\t-\n' >> "$PLAN"
```
In `SELFCHECK_CMD` add:
```bash
  [ratetests]="python3 -m pytest -q $REPO/tools/rate/tests"
  [ratestale]="python3 $REPO/tools/rate/rate.py status --check"
```
Add `ratetests|ratestale|` to the `run_selfcheck` case list (the line beginning `runguard|ipsync|splitplan|...`).

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/ratings/_gate_$(date +%H%M) bash sim/regress.sh --only rate --keep`
Expected: `OVERALL PASS 2`. `PASS 0` means the substring matched nothing: read the row names.

- [ ] **Step 6: Commit**

```bash
git diff -- sim/regress.sh     # read it: only the three additions
git add tools/rate/rate.py tools/rate/tests/test_status.py sim/regress.sh
git commit -m "rate: status with a staleness gate (sim:ratestale) and the flow's unit tests as sim:ratetests"
```

---

### Task 9: The remaining rows on the VU33P

**Files:**
- Modify: `hw/targets/blocks.json`, `hw/targets/levers.json` (only if NWIDE's owner moves), `hw/targets/binds/QWEN35_9B.json`
- Create (generated): `hw/targets/ratings/vu33p_fk33/*.QWEN35_9B.json`

- [ ] **Step 1: Bind the remaining cells**

Re-run `binds.tcl` on `llama_top` for cells: `u_gdn u_jobseq u_state u_attn u_fetch u_opdec u_vissue u_vres u_lock u_rms u_swg u_smp`, and on the card cell (`hw/fk33/rtl/fk33_card.vhd`) for one `region_mem` instance per distinct generic set and the `bc_port_grant` instance. Update `hw/targets/binds/QWEN35_9B.json`.

- [ ] **Step 2: Add one row per cell**

Rows (top, tier, levers):

| row | top | tier | levers (explicit value) |
|---|---|---|---|
| `b_gdn` | `gdn_block` | core | none |
| `b_seq` | `gdn_job_seq` | core | none |
| `b_state` | `gdn_state_store` | core | `NWIDE` `false` |
| `c_attn` | `attn_block` | core | `SWEEP_PIPE` `false`, `SCORE_EARLY` `false` |
| `d_fetch` | `seq_desc_fetch` | core | none |
| `d_opdec` | `seq_opdec` | core | none |
| `d_vissue` | `seq_vec_issue` | core | none |
| `d_vres` | `seq_vec_res` | core | none |
| `d_lock` | `seq_region_lock` | core | none |
| `v_rms` | `rmsnorm_bf_mem` | core | none |
| `v_swg` | `swiglu_mem` | core | none |
| `v_smp` | `sampler_stream` | core | none |
| `g_region_<n>` | `region_mem` | core | none (one row per distinct generic set) |
| `g_grant` | `bc_port_grant` | core | none |

Each row: `clocks {"clk": "*"}`, `target_ns 10.0` (100 MHz, i.e. 33% above today's 75 MHz core, ESTIMATE; the lower-bound flag tells you to tighten it), generics from the binds. Also add `c_attn_levers` (same top, both levers listed, both `true`) and `b_state_nwide` (`NWIDE` `true`): the lever-on arms are rated so the manifest records what each lever costs or buys in fmax and area. Both arms list the levers; the validator requires it.

- [ ] **Step 3: Run the depth pre-gate on every row first (minutes each)**

```bash
for r in b_gdn b_seq b_state c_attn d_fetch d_opdec d_vissue d_vres d_lock v_rms v_swg v_smp g_grant; do
  python3 tools/rate/rate.py run $r --device vu33p_fk33 --model QWEN35_9B --mode pregate
done
```
Record the levels; compare with `predict.max_levels(1000/target_ns, table)`.

- [ ] **Step 4: Rate every row (routed), queued one at a time**

Same loop with `--mode route`. `c_attn` peaked 10.85 GB on the BC-250 (MEASURED): keep it on the workstation. Each record's `fmax_is_lower_bound` true means tighten that row's `target_ns` and re-rate.

- [ ] **Step 5: Status and commit**

Run: `python3 tools/rate/rate.py status` -> every VU33P row FRESH.
```bash
git add hw/targets/blocks.json hw/targets/levers.json hw/targets/binds/QWEN35_9B.json hw/targets/ratings/vu33p_fk33/
git commit -m "rate: all Qwen3.5-9B blocks rated on the VU33P (-2LV), pre-gate depths recorded"
```

---

### Task 10: The BC-250 lane

**Files:**
- Modify: `tools/rate/vivado.py` (remote runner), `tools/rate/rate.py` (`--lane local|bc250`)
- Test: manual cross-lane check

- [ ] **Step 1: Implement the remote runner**

Add to `vivado.py`:
```python
def bc250_host():
    r = subprocess.run(["ssh", "labuser@192.0.2.1", "grep -i cachyos /var/lib/misc/dnsmasq.leases"],
                       capture_output=True, text=True)
    parts = r.stdout.split()
    if len(parts) < 3:
        raise SystemExit("BC-250 has no lease on the router; resolve it before dispatch (CLAUDE.md)")
    return parts[2]

def run_batch_bc250(tcl, args, workdir, mem_high="11G", unit="rate-job"):
    """Same contract as run_batch, on the BC-250. workdir is a LOCAL path; the remote
    work directory mirrors it under /home/orencollaco/ratings/. Tree paths inside `args`
    and the file list must already use the /home/orencollaco/GitHub/llama.vhdl prefix
    (the sync destination, identical on both boxes)."""
    if int(mem_high.rstrip("G")) > 11:
        raise SystemExit("REFUSED: MemoryHigh above 11G on the BC-250 (CLAUDE.md)")
    host = "labuser@" + bc250_host()
    subprocess.run(["bash", os.path.expanduser("~/GitHub/DevOps/bc250-sync-llama-vhdl.sh")], check=True)
    rwd = "/home/orencollaco/ratings/" + os.path.relpath(workdir, config.WORK_ROOT)
    # Push the harness inputs that live only in the local workdir (shell, file list).
    subprocess.run(["ssh", host, "mkdir -p " + shlex.quote(rwd)], check=True)
    for f in ("rate_shell.vhd", "files.txt"):
        lp = os.path.join(workdir, f)
        if os.path.exists(lp):
            subprocess.run(["scp", "-q", lp, "%s:%s/%s" % (host, rwd, f)], check=True)
    rargs = [a.replace(workdir, rwd) for a in args]
    log = rwd + "/vivado.log"
    high = int(mem_high.rstrip("G")) * 1024 ** 3
    script = "\n".join([
        "set -u",
        "export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus",
        "for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue;"
        " case \"$e\" in *unwrapped/lnx64.o/vivado*) echo RATE_REFUSED_VIVADO_PRESENT; exit 1;; esac; done",
        "sed -i 's#%s#%s#g' %s/files.txt" % (workdir, rwd, rwd),
        "cat > %s/run.sh <<'RUNEOF'" % rwd,
        "#!/usr/bin/env bash",
        "source %s/settings64.sh" % config.VIVADO_ROOT,
        "cd %s" % rwd,
        "vivado -mode batch -nojournal -log %s -source %s -tclargs %s"
        % (log, tcl, " ".join(shlex.quote(x) for x in rargs)),
        "rc=$?",
        "cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)",
        "echo \"RATE_MEM peak $(cat $cg/memory.peak) swap_peak $(cat $cg/memory.swap.peak 2>/dev/null || echo NA) rc $rc\" >> %s" % log,
        "RUNEOF",
        "chmod +x %s/run.sh" % rwd,
        "systemd-run --user --unit=%s -p MemoryHigh=%s -p MemoryMax=%dG %s/run.sh"
        % (unit, mem_high, int(mem_high.rstrip("G")) + 1, rwd),
        "sleep 3",
        # The readback IS the guard: without it an uncapped Vivado on a 14 GB box is invisible.
        "got=$(systemctl --user show %s -p MemoryHigh --value)" % unit,
        "[ \"$got\" = \"%d\" ] || { echo RATE_REFUSED_CAP_NOT_APPLIED $got; systemctl --user stop %s; exit 1; }" % (high, unit),
        "while systemctl --user is-active --quiet %s; do sleep 20; done" % unit,
        "echo RATE_REMOTE_DONE",
    ]) + "\n"
    r = subprocess.run(["ssh", host, "bash -s"], input=script, text=True, capture_output=True)
    if "RATE_REMOTE_DONE" not in r.stdout:
        raise SystemExit("BC-250 run did not complete:\n" + r.stdout + r.stderr)
    subprocess.run(["scp", "-q", "-r", "%s:%s/." % (host, rwd), workdir], check=True)
    text = open(os.path.join(workdir, "vivado.log")).read()
    m = re.search(r"^RATE_MEM peak (\d+) swap_peak (\S+) rc (\d+)\s*$", text, re.M)
    return {"log": text, "rc": int(m.group(3)) if m else 1,
            "mem_peak": int(m.group(1)) if m else None,
            "swap_peak": int(m.group(2)) if m and m.group(2).isdigit() else None}
```
The remote shell is fish, so the script always goes through `ssh host 'bash -s'` on stdin (CLAUDE.md, MEASURED 2026-09-19). In `rate.py`, `--lane bc250` selects `vivado.run_batch_bc250` in place of `vivado.run_batch` and defaults `--mem` to `11G`; the tree must be the repo (`--tree` other than `config.REPO` is refused on this lane, because only the repo is synced).

- [ ] **Step 2: Cross-lane check**

Rate `calib_lut_d4` on the BC-250 lane: `python3 tools/rate/rate.py run calib_lut_d4 --device vu33p_fk33 --model CALIB --lane bc250`
Expected: routed WNS identical to the local record (CLAUDE.md: results are bit-identical across the two machines). A difference stops the lane until explained.

- [ ] **Step 3: Commit**

```bash
git add tools/rate/vivado.py tools/rate/rate.py
git commit -m "rate: BC-250 lane (router-resolved host, 11G cap with readback, sync first); cross-lane identical"
```

---

### Task 11: VU35P rows

**Files:**
- Modify: `hw/targets/devices.json`
- Create (generated): `hw/targets/calib/vu35p_jc_*.json`, `hw/targets/ratings/vu35p_jc_*/`

- [ ] **Step 1: Add one device row per candidate grade**

```json
"vu35p_jc_m1":  {"build_part": "xcvu35p-fsvh2104-1-e",  "rating_part": "xcvu35p-fsvh2104-1-e",  "vccint_run": 0.85, "board": "jungle_cat", "resources": null},
"vu35p_jc_m2":  {"build_part": "xcvu35p-fsvh2104-2-e",  "rating_part": "xcvu35p-fsvh2104-2-e",  "vccint_run": 0.85, "board": "jungle_cat", "resources": null},
"vu35p_jc_m2l": {"build_part": "xcvu35p-fsvh2104-2L-e", "rating_part": "xcvu35p-fsvh2104-2LV-e", "vccint_run": 0.72, "board": "jungle_cat", "resources": null},
"vu35p_jc_m3":  {"build_part": "xcvu35p-fsvh2104-3-e",  "rating_part": "xcvu35p-fsvh2104-3-e",  "vccint_run": 0.90, "board": "jungle_cat", "resources": null}
```
`vccint_run` for these is the grade's nominal (ESTIMATE until the unit is characterised). Run `devices.refresh()`; a part Vivado does not have prints `PARTPROP_MISSING` and the refresh refuses: delete that row rather than inventing it.

- [ ] **Step 2: Calibrate and rate**

`python3 tools/rate/calib.py vu35p_jc_m2` (and each other grade), then every manifest row per grade (Task 9's loop with `--device`). The BC-250 lane (Task 10) takes rows under 11 GB.

- [ ] **Step 3: Commit**

```bash
git add hw/targets/devices.json hw/targets/calib/ hw/targets/ratings/
git commit -m "rate: VU35P at each candidate grade, calibrated and rated"
```

---

### Task 12: Tier prediction, the composition derate k, and preflight

**Files:**
- Create: `tools/rate/tiers.py`
- Modify: `tools/rate/rate.py` (`k`, `predict`, `preflight` subcommands)
- Create (generated): `hw/targets/k/vu33p_fk33.json`
- Test: `tools/rate/tests/test_tiers.py`

**Interfaces:**
- Produces: `tiers.tier_min(records, tier) -> (mhz, row)`; `tiers.k_from_build(card_period_ns, card_wns, tier_min_mhz) -> {"k": float, "lower_bound": bool}`; `tiers.predict(records, kfile) -> {tier: mhz}`; `rate.py preflight --device D --model M --levers NAME=VAL,...` printing `^PREFLIGHT_OK` and `FK33_ENG_CORE_MHZ=<int>` / `FK33_ENG_FAST_MHZ=<int>` lines, or `^PREFLIGHT_REFUSED <reason>` and exit 1.

- [ ] **Step 1: Write the failing tests**

`tools/rate/tests/test_tiers.py`:
```python
import pytest, tiers

RECS = [{"row": "c_attn", "tier": "core", "achieved_mhz": 120.0},
        {"row": "d_fetch", "tier": "core", "achieved_mhz": 250.0},
        {"row": "a_engine", "tier": "stream", "achieved_mhz": 210.0}]

def test_tier_min():
    assert tiers.tier_min(RECS, "core") == (120.0, "c_attn")

def test_k_from_a_build_that_met_timing_is_a_lower_bound():
    k = tiers.k_from_build(13.333, 0.032, 120.0)          # build 20: met 75 MHz with +0.032
    assert k["lower_bound"] is True
    assert k["k"] == pytest.approx((1000 / (13.333 - 0.032)) / 120.0)

def test_k_from_a_failing_build_is_exact():
    assert tiers.k_from_build(5.0, -1.0, 200.0)["lower_bound"] is False

def test_predict_uses_worst_k():
    kf = {"core": [{"k": 0.7, "lower_bound": False}, {"k": 0.6, "lower_bound": True}]}
    assert tiers.predict(RECS, kf)["core"] == pytest.approx(0.6 * 120.0)

def test_predict_refuses_without_k():
    with pytest.raises(SystemExit, match="first card build"):
        tiers.predict(RECS, {})
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m pytest tools/rate/tests/test_tiers.py -q` -> FAIL (`No module named 'tiers'`).

- [ ] **Step 3: Implement**

`tools/rate/tiers.py`:
```python
"""tools/rate/tiers.py -- predicted tier clocks = worst measured k x slowest block in the tier.
k from a card build that MET its target is a LOWER BOUND (Vivado stops optimising once met)."""

def tier_min(records, tier):
    rs = [r for r in records if r["tier"] == tier]
    if not rs:
        raise SystemExit("no rated block in tier %s" % tier)
    r = min(rs, key=lambda r: r["achieved_mhz"])
    return r["achieved_mhz"], r["row"]

def k_from_build(card_period_ns, card_wns, tier_min_mhz):
    card_mhz = 1000.0 / (card_period_ns - card_wns)
    return {"k": card_mhz / tier_min_mhz, "lower_bound": card_wns >= 0}

def predict(records, kfile):
    out = {}
    for tier in sorted({r["tier"] for r in records if r["tier"] != "calib"}):
        ks = kfile.get(tier)
        if not ks:
            raise SystemExit("no k for tier %s on this part: the first card build on a part is the "
                             "calibration of k (spec section 4)" % tier)
        mhz, _ = tier_min(records, tier)
        out[tier] = min(k["k"] for k in ks) * mhz
    return out
```

Add `rate.py k --device D --model M --tier core --card-period 13.333 --card-wns 0.032 --build 20 --clb-util 99.8` which loads the FRESH records of that device/model **rated on the build's own tree** (`--tree /mnt/storage/fk33_builds/wt20`; rate the core rows there first with `rate.py run ... --tree`, records written under `hw/targets/ratings/vu33p_fk33/tree_build20/`). Add the option to `cmd_run`'s parser, `r.add_argument("--record-dir")`, and in `cmd_run` use `dst = os.path.join(a.record_dir, "%s.%s.json" % (a.row, a.model)) if a.record_dir else <the existing dst>`, so tree-calibration ratings never overwrite current-tree ratings) and appends `{"k", "lower_bound", "build", "clb_util"}` to `hw/targets/k/<device>.json` under the tier.

Add `rate.py preflight --device D --model M --levers SWEEP_PIPE=false,...`:
1. `status` has no STALE and no UNRATED row for (D, M): else `PREFLIGHT_REFUSED stale/unrated <rows>`.
2. every row's pre-gate levels <= `predict.max_levels(predicted tier MHz, table)`: else refuse naming the row.
3. every lever set `true` has `levers.json` `silicon: proven`, unless `--proving <LEVER>` names it: else refuse (build 19 as a refusal).
4. print `PREFLIGHT_OK` and `FK33_ENG_CORE_MHZ=<floor(core)>`, `FK33_ENG_FAST_MHZ=<floor(stream)>`.

Tests for preflight's lever rule, in `test_tiers.py`:
```python
def test_unproven_lever_refused(tmp_path):
    import rate
    with pytest.raises(SystemExit, match="silicon"):
        rate.lever_gate({"SWEEP_PIPE": "true"}, {"SWEEP_PIPE": {"top": "attn_block", "silicon": "unproven", "evidence": ""}}, proving=())

def test_proving_build_may_turn_one_on():
    import rate
    rate.lever_gate({"SWEEP_PIPE": "true"}, {"SWEEP_PIPE": {"top": "attn_block", "silicon": "unproven", "evidence": ""}},
                    proving=("SWEEP_PIPE",))
```
with, in `rate.py`:
```python
def lever_gate(levers_set, lever_table, proving=()):
    for name, val in levers_set.items():
        if val == "true" and lever_table[name]["silicon"] != "proven" and name not in proving:
            raise SystemExit("PREFLIGHT_REFUSED lever %s is on but not silicon-proven (%s)"
                             % (name, lever_table[name]["evidence"]))
```

- [ ] **Step 4: Run the tests, then calibrate k on the VU33P**

Run: `python3 -m pytest tools/rate/tests -q` -> all pass.
Rate the core rows on build 20's and build 21's trees (`wt20`, `wt21`), then:
```bash
python3 tools/rate/rate.py k --device vu33p_fk33 --model QWEN35_9B --tier core --card-period 13.333 --card-wns 0.032 --build 20 --tree /mnt/storage/fk33_builds/wt20
python3 tools/rate/rate.py k --device vu33p_fk33 --model QWEN35_9B --tier core --card-period 13.333 --card-wns 0.005 --build 21 --tree /mnt/storage/fk33_builds/wt21
python3 tools/rate/rate.py preflight --device vu33p_fk33 --model QWEN35_9B --levers FAST_POP=false,NWIDE=false,SWEEP_PIPE=false,SCORE_EARLY=false
```
Expected: two k entries, both `lower_bound: true` (both builds met 75 MHz), and `PREFLIGHT_OK` with a core MHz at or above 75. Record in `hw/targets/k/README.md` that every VU33P k so far is a lower bound, so the prediction is conservative until a card build is launched at the predicted clock.

- [ ] **Step 5: Commit**

```bash
git add tools/rate/tiers.py tools/rate/rate.py tools/rate/tests/test_tiers.py hw/targets/k/vu33p_fk33.json hw/targets/k/README.md hw/targets/ratings/vu33p_fk33/tree_build20 hw/targets/ratings/vu33p_fk33/tree_build21
git commit -m "rate: tier clock prediction with a measured composition derate (lower bounds from builds 20/21), and preflight"
```

---

## Deferred (spec, not this plan)

- Approach B (locked, floorplanned block reuse): after the VU35P's first card build.
- Replacing `build12_levers_off.patch` in `hw/fk33/pcieep_build.sh` with the manifest's lever values: a separate change once preflight has been used for one card build.
- The tier boundary rule (a tier crossing only on an existing FIFO/stream interface) as a
  CHECK: this plan records each row's tier; enforcing the boundary needs the card's
  connectivity and belongs with the first multi-tier card build.
- Retiring the 78 `sim/ooc_*.tcl` harnesses: each retires only after its block's row is rated
  and, where one of the 5 routed harnesses covers it on the same tree, agrees with it.
