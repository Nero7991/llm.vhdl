"""hw/jc/card/test_ooc27.py -- Task 10.  Dry-run assertions on run_ooc27.sh
(the orchestration) and static assertions on ooc_card_200.tcl (the Vivado
flow it calls). No Vivado, no git side effects, no hardware: `run_ooc27.sh
--dry-run` only prints the commands and parameter bindings it would use, and
the real-run-only refusal (another Vivado) is never enforced under --dry-run
(the header comment in run_ooc27.sh explains why, same reasoning as
run_card.sh's own dry-run test).

    python3 -m pytest hw/jc/card/test_ooc27.py -q
"""
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
RUN_OOC27 = os.path.join(HERE, "run_ooc27.sh")
OOC_TCL = os.path.join(HERE, "ooc_card_200.tcl")
BUILD_CARD_TCL = os.path.join(HERE, "build_card.tcl")
PATCH = os.path.join(REPO, "hw", "fk33", "results", "card_build20_2026-09-24",
                      "build12_levers_off.patch")


def _dry_run(root, extra=(), flags=()):
    """--dry-run always needs --allow-scratch-root here: every test root is
    under pytest's tmp_path, never under /mnt/storage/fk33_builds/."""
    args = ["bash", RUN_OOC27, "--dry-run", "--allow-scratch-root", *flags, root, *extra]
    return subprocess.run(args, cwd=REPO, capture_output=True, text=True)


def _run_raw(args):
    return subprocess.run(["bash", RUN_OOC27, *args], cwd=REPO, capture_output=True, text=True)


def _tcl_text():
    with open(OOC_TCL) as f:
        return f.read()


def _sh_text():
    with open(RUN_OOC27) as f:
        return f.read()


# ---- run_ooc27.sh --dry-run: the basics -------------------------------------

def test_dry_run_exits_zero(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert r.returncode == 0, r.stderr


def test_dry_run_touches_nothing(tmp_path):
    root = tmp_path / "root"
    _dry_run(str(root))
    assert not root.exists(), "dry-run must not create <root> or anything under it"


def test_dry_run_never_prints_the_real_done_sentinel(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert not re.search(r"^JCOOC27_DONE$", r.stdout, re.M), (
        "a dry run must never print the bare JCOOC27_DONE line an automated "
        "caller gates on; it must print the DRYRUN-prefixed form instead")
    assert "DRYRUN would write: JCOOC27_DONE" in r.stdout


def test_dry_run_applies_the_levers_patch(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert re.search(r"git\s+-C\s+\S+\s+apply\s+--check\s+" + re.escape(PATCH), r.stdout), (
        "a clean --check must be proven before the real apply")
    assert re.search(r"git\s+-C\s+\S+\s+apply\s+" + re.escape(PATCH), r.stdout)
    assert PATCH in r.stdout


def test_dry_run_part_string(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "xcvu35p-fsvh2104-2L-e" in r.stdout


def test_dry_run_regenerates_27b_card_only_not_the_bd(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "FK33_MODEL=QWEN38_27B" in r.stdout
    assert "FK33_C_MAXPOS=16384" in r.stdout
    assert "gen_fk33_card.py" in r.stdout
    # the Task 9 BD generator must NOT run here: this is an OOC flow with no
    # block design, no HBM IP, no jc_card_top.
    assert "gen_jc_card.py" not in r.stdout


def test_dry_run_generates_the_composed_top(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "gen_ooc27_top.py" in r.stdout
    assert "--haddr-w 15" in r.stdout
    assert "--regmax 17408" in r.stdout


def test_dry_run_launches_under_run_capped(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert re.search(r"run_capped\.sh\b", r.stdout)
    assert "ooc_card_200.tcl" in r.stdout


def test_dry_run_default_mem_cap(tmp_path):
    """Fix round 1, I3: 22G, not 12G. Vivado's own log from the reference
    runs reports 11780 MB peak for the 27B fk33_card OOC alone and 9008 MB
    for fk33_engine OOC alone; this composition is both together in one
    placement, ESTIMATE 16-20 GB, so 22G (not the old 4-8 GB-derived 12G)."""
    r = _dry_run(str(tmp_path / "root"))
    assert "mem_high=22G" in r.stdout


def test_dry_run_accepts_a_cap_override(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-2L-e", "6G"])
    assert "mem_high=6G" in r.stdout


def test_dry_run_swap_guard_is_fixed_4gib(tmp_path):
    """Fix round 1, I3: a FIXED 4 GiB swap guard, not a multiple of the
    requested cap (swap in use at all is the leading indicator, not a
    fraction of whatever cap was asked for) -- checked at two different
    caps to prove it really is fixed, not merely matching one coincidence."""
    r1 = _dry_run(str(tmp_path / "root1"))
    assert "swap_kill_bytes=4294967296" in r1.stdout
    r2 = _dry_run(str(tmp_path / "root2"), extra=["xcvu35p-fsvh2104-2L-e", "6G"])
    assert "swap_kill_bytes=4294967296" in r2.stdout


def test_dry_run_prints_memory_budget(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "JCOOC27_MEMORY_BUDGET" in r.stdout
    assert "MemAvailable=" in r.stdout
    assert "SwapFree=" in r.stdout


def test_sh_refuses_below_cap_plus_2g_memavailable():
    """Fix round 1, I3: refuse if MemAvailable < cap + 2G. Not exercised
    under --dry-run (the refusal itself is disabled there, same reasoning as
    the Vivado-presence refusal), so this asserts the REFUSAL CODE is
    present and reads MemAvailable against cap+2GiB, not that it fires."""
    text = _sh_text()
    assert "HEADROOM_BYTES=2147483648" in text
    assert re.search(r"MEMAVAIL.*-lt.*CAP_BYTES \+ HEADROOM_BYTES", text) or \
           re.search(r'"\$MEMAVAIL"\s*-lt\s*"\$\(\(CAP_BYTES \+ HEADROOM_BYTES\)\)"', text)
    assert "below cap" in text


def test_sh_pre_vivado_lever_grep_is_fatal():
    """Fix round 1, I6: a FATAL grep of the patched sources for FAST_POP
    default false, NWIDE/SWEEP_PIPE/SCORE_EARLY => false, and PIPE/WIDE/
    MAXOUT 8 present, BEFORE Vivado runs -- independent of whether Vivado's
    own elaboration trace ever reaches this script's log."""
    text = _sh_text()
    for pat in ["FAST_POP : boolean := false", "NWIDE        => false,",
                "SWEEP_PIPE => false, SCORE_EARLY => false)",
                "PIPE         => true,", "WIDE         => true)",
                "MAXOUT       => 8,"]:
        assert pat in text, "missing pre-Vivado lever pattern: %r" % pat
    assert "jcooc27_fail" in text
    assert "LEVERS_PRE_CHECKS" in text


def test_sh_post_run_lever_check_is_fatal_on_on_or_mixed():
    """Fix round 1, I6: the post-run read-back must fail the run on 'on' or
    'mixed', non-fatal only on 'missing'."""
    text = _sh_text()
    assert 'status eq "on" || $status eq "mixed"' in text
    assert "exit 1" in text.split("JCOOC27_LEVER_FAIL")[1][:60]
    assert "jcooc27_fail \"levers (post-run" in text


def test_sh_runs_the_generator_itself_from_the_archived_src_not_here():
    """Fix round 3, item 4: the GENERATOR ITSELF (gen_ooc27_top.py) must be
    read from the archived $SRC, never from $HERE (the live checkout) --
    otherwise a run against an older/different commit's $SRC would still
    execute THIS session's live generator, silently breaking the
    provenance step 1's own `git archive HEAD` copy exists to establish."""
    text = _sh_text()
    assert '"$HERE/gen_ooc27_top.py"' not in text
    assert '"$SRC/hw/jc/card/gen_ooc27_top.py"' in text


def test_refuses_root_outside_fk33_builds_without_the_escape_hatch(tmp_path):
    r = subprocess.run(["bash", RUN_OOC27, "--dry-run", str(tmp_path / "root")],
                        cwd=REPO, capture_output=True, text=True)
    assert r.returncode != 0
    assert "JCOOC27_FAIL" in r.stdout
    assert "/mnt/storage/fk33_builds/" in r.stdout


def test_refuses_other_part_without_the_escape_hatch(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-1-e"])
    assert r.returncode != 0
    assert "JCOOC27_FAIL" in r.stdout
    assert "xcvu35p-fsvh2104-1-e" in r.stdout


def test_refuses_a_nonempty_root(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    (root / "stale.txt").write_text("leftover")
    r = _dry_run(str(root))
    assert r.returncode != 0
    assert "JCOOC27_FAIL" in r.stdout
    assert "already exists and is not empty" in r.stdout


def test_usage_on_no_args():
    r = _run_raw([])
    assert r.returncode == 2
    assert "usage" in r.stderr


# ---- static assertions on ooc_card_200.tcl ---------------------------------

def test_tcl_contains_route_design():
    assert re.search(r"^route_design\s*$", _tcl_text(), re.M), (
        "CLAUDE.md: check that an OOC script contains route_design before "
        "quoting any fmax from it -- no WNS before route_design is a result")


def test_tcl_contains_the_2l_part():
    text = _tcl_text()
    assert "xcvu35p-fsvh2104-2L-e" in text
    # the default, not merely mentioned in a comment: the actual default binding
    assert re.search(r'set part\s+\[expr\s*\{.*xcvu35p-fsvh2104-2L-e', text)


def test_tcl_contains_the_5000ns_clock():
    text = _tcl_text()
    assert re.search(r"set ACLK_P\s+5\.000", text)
    assert "create_clock" in text
    assert "5.000" in text


def test_tcl_sentinels_are_anchored():
    text = _tcl_text()
    for pat in [r'puts\s+"JCOOC27_ROUTE', r'puts\s+"JCOOC27_WNS',
                r'puts\s+"JCOOC27_WHS', r'puts\s+"JCOOC27_WORST10',
                r'puts\s+"JCOOC27_UTIL', r'puts\s+"JCOOC27_DONE']:
        assert re.search(pat, text), "missing anchored sentinel: %s" % pat
    # JCOOC27_DONE is the LAST thing printed
    lines = [l for l in text.splitlines() if "puts" in l and "JCOOC27_" in l]
    assert "JCOOC27_DONE" in lines[-1]


def test_tcl_reports_worst_10_paths_with_clocks_and_hierarchy():
    text = _tcl_text()
    # fix round 1, M2: -nworst 1 (one path per ENDPOINT), not -nworst 10
    # (up to ten paths to the SAME endpoint; the "worst 10" must be ten
    # distinct endpoints, not one endpoint's ten worst paths).
    assert re.search(r"get_timing_paths\s+-max_paths\s+10\s+-nworst\s+1\s+-setup", text)
    assert "STARTPOINT_CLOCK" in text
    assert "ENDPOINT_CLOCK" in text
    assert "STARTPOINT_PIN" in text
    assert "ENDPOINT_PIN" in text


def test_tcl_route_fail_prevents_done():
    """Fix round 1, M1: a routing failure must stop the script before
    ^JCOOC27_DONE, not merely print ROUTE_FAIL and continue to it."""
    text = _tcl_text()
    m = re.search(r"report_route_status -return_string.*?\n(.*?)\n\n", text, re.S)
    route_block = m.group(0)
    assert re.search(r"jcoo27_fail\b", route_block), (
        "the route-status branch(es) must call the abort proc, not just print")
    # textually, every jcoo27_fail call in the route block must precede the
    # file's own JCOOC27_DONE line
    done_pos = text.index('puts "JCOOC27_DONE"')
    for m2 in re.finditer(r"jcoo27_fail", route_block):
        assert text.index(route_block) + m2.start() < done_pos


def test_tcl_nonce_printed_first():
    """Fix round 1, I2: the nonce must be read from -tclargs and printed
    before anything else (JCOOC27_PART, the source reads, synth_design),
    exactly as build_card.tcl's JCCARD_NONCE is -- not appended to the log
    file by run_ooc27.sh after the fact, which Vivado's own -log rotation
    silently discards."""
    text = _tcl_text()
    assert "-nonce" in text
    nonce_pos = text.index('puts "JCOOC27_NONCE')
    part_pos = text.index('puts "JCOOC27_PART')
    assert nonce_pos < part_pos


def test_tcl_scope_sentinel():
    """Fix round 1, I5: the result covers internal reg-to-reg paths only,
    because the I/O ports carry no input/output delay (other than the
    registered-reset buffer's own single-flop input delay and compute_
    halt's false path) -- state that in the log itself, not only in prose."""
    text = _tcl_text()
    assert re.search(r'puts\s+"JCOOC27_SCOPE\s+internal_reg_to_reg_only\s+io_untimed"', text)


def test_tcl_compute_halt_is_false_pathed_not_input_delayed():
    """Fix round 1, I4: compute_halt gets set_false_path, matching build_
    card.tcl:342's own treatment of CATTRIP (asynchronous/quasi-static, no
    synchroniser) -- not a timed input delay, which the original version
    gave it (and rst/rstn, before they were registered)."""
    text = _tcl_text()
    # ooc_card_200.tcl builds this as a Tcl STRING (inside the running Vivado
    # process, not the shell), so [ and ] are backslash-escaped in the
    # source to keep Tcl from treating them as command substitution.
    assert re.search(r"set_false_path\s+-from\s+\\?\[get_ports\s+compute_halt\\?\]", text)
    assert not re.search(r"set_input_delay[^\n]*compute_halt", text)


def test_tcl_reports_utilisation_with_percentages():
    text = _tcl_text()
    for row in ["CLB LUTs", "CLB Registers", "Block RAM Tile", "URAM", "DSPs"]:
        assert row in text
    assert "pct" in text


def test_tcl_file_list_entries_all_resolve_in_a_prepared_tree(tmp_path):
    """Every path ooc_card_200.tcl reads must exist once run_ooc27.sh has
    prepared the tree -- git archive HEAD, the levers patch, and the 27B
    fk33_card.vhd regeneration -- so a path this test cannot find in a plain
    `git archive HEAD` extraction (patch and regeneration do not ADD files,
    only edit/rewrite existing ones) is a real typo, not a false positive."""
    text = _tcl_text()
    m = re.search(r"set VHDL_FILES \[list \\\n(.*?)\]\n", text, re.S)
    assert m, "could not find the VHDL_FILES list"
    files = re.findall(r"[A-Za-z0-9_./]+\.vhd", m.group(1))
    assert len(files) > 60
    # jc_ooc27_top.vhd is written by gen_ooc27_top.py, not present in a bare
    # archive: checked separately against test_gen_ooc27_top.py instead.
    files = [f for f in files if f != "hw/jc/card/jc_ooc27_top.vhd"]
    extract = tmp_path / "extract"
    extract.mkdir()
    subprocess.run("git archive HEAD | tar -x -C %s" % extract, shell=True,
                    cwd=REPO, check=True)
    missing = [f for f in files if not (extract / f).exists()]
    assert not missing, "missing from a plain git archive HEAD: %s" % missing


def test_tcl_excludes_the_9b_model_package():
    """rtl/model_cfg_pkg.vhd (the 9B binding) must never be READ alongside
    the 27B package: build_card.tcl's own documented reason (both bind the
    package name model_cfg_pkg; whichever read_vhdl runs last silently wins,
    with no error from Vivado). Scoped to the VHDL_FILES list itself, not
    this file's prose, which names rtl/model_cfg_pkg.vhd to explain why."""
    text = _tcl_text()
    m = re.search(r"set VHDL_FILES \[list \\\n(.*?)\]\n", text, re.S)
    body = m.group(1)
    assert "hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd" in body
    assert "rtl/model_cfg_pkg.vhd" not in body


def test_tcl_and_build_card_source_lists_do_not_drift():
    """ooc_card_200.tcl's ENG_SRCS/CARD_2008-derived entries must all also
    appear in build_card.tcl's own ENG_SRCS/CARD_2008 Tcl lists (Task 9), so
    a source added or removed there is caught here rather than six hours
    into a Vivado run."""
    ooc_text = _tcl_text()
    card_text = open(BUILD_CARD_TCL).read()
    m = re.search(r"set VHDL_FILES \[list \\\n(.*?)\]\n", ooc_text, re.S)
    ooc_files = set(re.findall(r"[A-Za-z0-9_./]+\.vhd", m.group(1)))
    skip = {"hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd", "hw/jc/card/jc_ooc27_top.vhd"}
    # build_card.tcl names most of these inside Tcl lists ($repo-relative, no
    # variable prefix) but fk33_engine.vhd/fk33_seam.vhd/fk33_card.vhd via
    # `add_files -norecurse $repo/<path>`, so this checks CONTAINMENT
    # (the path appears somewhere in build_card.tcl's text) rather than
    # re-tokenising its own variable-prefixed paths with the same regex.
    only_here = [f for f in ooc_files if f not in skip and f not in card_text]
    assert not only_here, "sources read here but not by build_card.tcl: %s" % only_here
