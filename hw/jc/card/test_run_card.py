"""hw/jc/card/test_run_card.py -- Task 9, including fix round 1. Dry-run assertions
on run_card.sh (the orchestration) and static assertions on build_card.tcl (the
Vivado flow it calls). No Vivado, no git side effects, no hardware: `run_card.sh
--dry-run` only prints the commands and parameter bindings it would use, and the
real-run-only refusals (another Vivado, llama-server) are never enforced under
--dry-run (the header comment in run_card.sh explains why: a dry run's exit code
must not depend on what else happens to be running on the box).

    python3 -m pytest hw/jc/card/test_run_card.py -q
"""
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
RUN_CARD = os.path.join(HERE, "run_card.sh")
BUILD_CARD = os.path.join(HERE, "build_card.tcl")
PATCH = os.path.join(REPO, "hw", "fk33", "results", "card_build20_2026-09-24",
                      "build12_levers_off.patch")


def _dry_run(root, extra=(), flags=()):
    """--dry-run always needs --allow-scratch-root here: every test root is under
    pytest's tmp_path, never under /mnt/storage/fk33_builds/ (I4)."""
    args = ["bash", RUN_CARD, "--dry-run", "--allow-scratch-root", *flags, root, *extra]
    return subprocess.run(args, cwd=REPO, capture_output=True, text=True)


def _run_raw(args):
    """No automatic flags, for tests of the flags themselves."""
    return subprocess.run(["bash", RUN_CARD, *args], cwd=REPO, capture_output=True, text=True)


def _build_card_text():
    with open(BUILD_CARD) as f:
        return f.read()


def _run_card_text():
    with open(RUN_CARD) as f:
        return f.read()


# ---- run_card.sh --dry-run: the basics ---------------------------------------------

def test_dry_run_exits_zero(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert r.returncode == 0, r.stderr


def test_dry_run_touches_nothing(tmp_path):
    root = tmp_path / "root"
    _dry_run(str(root))
    assert not root.exists(), "dry-run must not create <root> or anything under it"


def test_dry_run_applies_the_levers_patch(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert re.search(r"git\s+-C\s+\S+\s+apply\s+--check\s+" + re.escape(PATCH), r.stdout), (
        "a clean --check must be proven before the real apply")
    assert re.search(r"git\s+-C\s+\S+\s+apply\s+" + re.escape(PATCH), r.stdout)
    assert PATCH in r.stdout, "the exact build12_levers_off.patch path must be printed"


def test_dry_run_part_string(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "xcvu35p-fsvh2104-2L-e" in r.stdout


def test_dry_run_clk_core_mhz_200(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "clk_core_mhz=200" in r.stdout
    assert "JC_CLK_CORE_MHZ=200" in r.stdout


def test_dry_run_memory_cap_24g(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "mem_high=24G" in r.stdout
    assert re.search(r"run_capped\.sh\b.*\b24G\b", r.stdout)


def test_dry_run_swap_guard_30gib(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    # 30 GiB in bytes, the project's standing card-build swap-guard constant.
    assert "32212254720" in r.stdout
    assert re.search(r"run_capped\.sh\b.*\b32212254720\b", r.stdout)


def test_dry_run_runs_vivado_under_run_capped(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert "hw/jc/loader/run_capped.sh" in r.stdout
    assert "vivado" in r.stdout
    assert "-mode batch" in r.stdout
    assert "build_card.tcl" in r.stdout


def test_dry_run_allow_neg_reaches_tclargs(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-2L-e", "allow_neg"])
    assert re.search(r"-tclargs\b.*\ballow_neg\b", r.stdout)


def test_dry_run_rejects_bad_third_argument(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-2L-e", "garbage"])
    assert r.returncode != 0


# ---- IMPORTANT I4: the root must be under /mnt/storage/fk33_builds/ ----------------

def test_root_outside_build_tree_is_refused_by_default(tmp_path):
    r = _run_raw(["--dry-run", str(tmp_path / "root")])
    assert r.returncode != 0
    assert "JCCARD_FAIL" in r.stdout
    assert "/mnt/storage/fk33_builds/" in r.stdout


def test_allow_scratch_root_overrides_the_location_check(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert r.returncode == 0, r.stdout + r.stderr


def test_dry_run_build_tree_root_needs_no_override(tmp_path):
    # a root that DOES start with the real build tree never needs the override; this
    # only proves the match is a prefix check, not that anything is written there
    # (--dry-run touches nothing regardless).
    root = "/mnt/storage/fk33_builds/__test_run_card_py_" + tmp_path.name
    r = _run_raw(["--dry-run", root])
    assert r.returncode == 0, r.stdout + r.stderr
    assert not os.path.exists(root)


# ---- IMPORTANT I3: a stale, non-empty root is refused before anything runs --------

def test_stale_nonempty_root_is_refused(tmp_path):
    root = tmp_path / "stale"
    root.mkdir()
    (root / "build.log").write_text("JCCARD_DONE\n")  # a stale sentinel from "before"
    r = _dry_run(str(root))
    assert r.returncode != 0
    assert "JCCARD_FAIL" in r.stdout
    assert "not empty" in r.stdout


def test_empty_existing_root_is_accepted(tmp_path):
    root = tmp_path / "empty"
    root.mkdir()
    r = _dry_run(str(root))
    assert r.returncode == 0, r.stdout + r.stderr


def test_build_log_rotated_before_launch():
    text = _run_card_text()
    assert re.search(r"rm\s+-f\s+\"\$BUILD_LOG\"", text)


# ---- IMPORTANT I3: the DONE gate needs THIS run's nonce, in order, not just any
#      JCCARD_DONE line in the log --------------------------------------------------

def test_dry_run_prints_a_nonce(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    m = re.search(r"\bnonce=(\S+)", r.stdout)
    assert m, r.stdout
    assert m.group(1) != ""


def test_nonce_reaches_tclargs(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert re.search(r"-tclargs\b.*-nonce\s+\S+", r.stdout)


def test_done_gate_requires_nonce_before_done_line():
    text = _run_card_text()
    assert "NONCE_LINE" in text and "DONE_LINE" in text
    assert re.search(r"grep\s+-nE\s+\"\^JCCARD_NONCE\s+\$\{?NONCE\}?", text)
    assert re.search(r"\"\$DONE_LINE\"\s*-gt\s*\"\$NONCE_LINE\"", text)


def test_build_card_prints_nonce_first_and_refuses_without_one():
    text = _build_card_text()
    assert 'puts "JCCARD_NONCE $nonce"' in text
    assert "no -nonce given" in text
    # the nonce line must precede JCCARD_PART in the script's own text, so it is
    # also first in the log Vivado writes (after Vivado's own startup banner).
    assert text.index('puts "JCCARD_NONCE $nonce"') < text.index('puts "JCCARD_PART $part"')


# ---- minor 7: the part string is pinned unless explicitly overridden --------------

def test_other_part_refused_without_override(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-1-e"])
    assert r.returncode != 0
    assert "JCCARD_FAIL" in r.stdout
    assert "--allow-other-part" in r.stdout


def test_other_part_accepted_with_override(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-1-e"],
                 flags=["--allow-other-part"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "xcvu35p-fsvh2104-1-e" in r.stdout
    assert "-tclargs" in r.stdout


# ---- IMPORTANT I5: process-presence refusals are static+documented, and are
#      skipped (not silently always-pass, SKIPPED) under --dry-run --------------------

def test_dry_run_never_enforces_process_presence_checks(tmp_path):
    # whatever is actually running on the box this test executes on, a dry run's
    # exit code must not depend on it.
    r = _dry_run(str(tmp_path / "root"))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "llama-server is running" not in r.stdout
    assert "another Vivado is already running" not in r.stdout


def test_vivado_presence_check_uses_proc_exe_not_pgrep():
    text = _run_card_text()
    assert "/proc/" in text
    assert "unwrapped/lnx64.o/vivado" in text
    assert "readlink" in text and "/exe" in text
    # "pgrep -f" and "cmdline" are named only in the explanatory comment (why NOT to
    # use them); there must be no actual `pgrep -f` INVOCATION.
    assert not re.search(r"^\s*pgrep\s+-f\b", text, re.M)
    assert not re.search(r"\bpgrep\s+-f\b.*vivado", text, re.I)


def test_llama_server_presence_check_and_override_flag():
    text = _run_card_text()
    assert "llama-server" in text
    assert "--allow-llama-server" in text
    assert "ALLOW_LLAMA_SERVER" in text


def test_memory_budget_printed_at_launch(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert re.search(r"JCCARD_MEMORY_BUDGET\b.*MemAvailable=", r.stdout)
    assert "SwapFree=" in r.stdout


# ---- run_card.sh: the sentinel is anchored, read from Vivado's own log -------------

def test_sentinel_grep_is_anchored():
    text = _run_card_text()
    assert re.search(r"grep\s+-nE\s+\"\^JCCARD_NONCE", text)
    assert re.search(r"grep\s+-nE\s+'\^JCCARD_DONE'", text)
    assert re.search(r"grep\s+-E\s+'\^JCCARD_FAIL'", text)


def test_sentinel_not_gated_on_exit_code_alone():
    text = _run_card_text()
    # the log line, not $RC, decides SENTINEL_OK
    assert "SENTINEL_OK" in text
    assert "$BUILD_LOG" in text


def test_pipefail_is_set():
    text = _run_card_text()
    assert re.search(r"^set\s+-\S*o\s+pipefail\S*$", text, re.M) or "pipefail" in text.splitlines()[0:40][0] or \
        any("pipefail" in l and l.strip().startswith("set") for l in text.splitlines())


# ---- minor 8: provenance records the regenerated files' own sha256 ----------------

def test_provenance_records_regenerated_file_hashes():
    text = _run_card_text()
    for f in ("jc_card_bd.tcl", "jc_card.xdc", "jc_card_top.vhd", "fk33_card.vhd"):
        assert f in text
    assert re.search(r"sha256sum\s+\"\$SRC/\$f\"", text) or "sha256sum" in text
    assert "PROVENANCE.txt" in text


# ---- minor 9: a dry run must never print a line starting with JCCARD_DONE --------

def test_dry_run_never_prints_a_line_starting_with_jccard_done(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert not re.search(r"^JCCARD_DONE", r.stdout, re.M), r.stdout
    assert "JCCARD_DONE" in r.stdout  # it is still mentioned, just not as that line


# ---- build_card.tcl: source list ---------------------------------------------------

def test_source_list_has_a_util_ctr():
    text = _build_card_text()
    assert "a_util_ctr.vhd" in text


def test_source_list_has_jc_ctl_core():
    text = _build_card_text()
    assert "jc_ctl_core.vhd" in text
    # jc_ctl_core.vhd itself must stay VHDL-93 (module-reference top); only the
    # units under it (jc_ctl_pkg, jc_ctl_frame_core, jc_ctl_exec) are 2008.
    assert "rtl/jc_ctl_core.vhd" in text
    assert "CTL_2008" in text and "jc_ctl_frame_core.vhd" in text


def test_source_list_has_27b_package():
    text = _build_card_text()
    assert "model_cfg_pkg_QWEN38_27B.vhd" in text


def test_source_list_excludes_the_9b_package():
    text = _build_card_text()
    # the 9B model_cfg_pkg.vhd must never be added directly: jc_card_bd.tcl refuses
    # the build if it is present in sources_1.
    assert "add_files -norecurse $repo/rtl/model_cfg_pkg.vhd" not in text


def test_part_default_is_2l():
    text = _build_card_text()
    assert "xcvu35p-fsvh2104-2L-e" in text


def test_vhdl2008_readback_loop_present():
    text = _build_card_text()
    assert "FILE_TYPE {VHDL 2008}" in text
    assert "VHDL 2008" in text and "jcc_fail" in text


# ---- build_card.tcl: CRITICAL C1, the lever check ----------------------------------

def test_lever_check_present():
    text = _build_card_text()
    for lever in ("NWIDE", "SWEEP_PIPE", "SCORE_EARLY"):
        assert lever in text
    assert "bound to" in text
    assert "JCCARD_LEVERS_OK" in text


def test_lever_check_refuses_on_missing_bind_line():
    # build_card.tcl's own "missing" branch is dynamic ($detail comes from the
    # shared proc); the literal message lives in jccard_levers.tcl, tested here
    # since that is what actually produces it (test_jccard_levers.py exercises the
    # proc itself against real log excerpts).
    with open(os.path.join(HERE, "jccard_levers.tcl")) as f:
        levers_text = f.read()
    assert "no bind line found" in levers_text
    text = _build_card_text()
    assert "missing" in text and "not applied, or the log moved" in text


def test_lever_check_uses_the_shared_parsing_proc():
    text = _build_card_text()
    assert "source $here/jccard_levers.tcl" in text
    assert "jccard_lever_status" in text


def test_lever_check_reads_the_synthesis_vds_not_runme_log():
    # CRITICAL C1 (second half): the deep elaboration trace carrying
    # NWIDE/SWEEP_PIPE/SCORE_EARLY lives only in <top>.vds, never in runme.log
    # (MEASURED on three real builds: see jccard_levers.tcl's header and
    # test_jccard_levers.py's fixtures). "runme.log" is still named in the
    # explanatory comment (why NOT to read it); the actual log-path ASSIGNMENT
    # must build a `.vds` path and must not reference runme.log.
    # (2026-10-07: gathered from every synthesis run's *.vds; see the test below.)
    text = _build_card_text()
    i = text.index("source $here/jccard_levers.tcl")
    j = text.index("JCCARD_LEVERS_OK", i)
    assert re.search(r"glob -nocomplain -directory .* \*\.vds", text[i:j])
    for line in text[i:j].splitlines():
        if not line.strip().startswith("#"):
            assert "runme.log" not in line


# ---- build_card.tcl: CRITICAL C2, the BSCAN check ----------------------------------

def _census_text():
    """build_card.tcl gathers the census; jccard_post.tcl's jccard_census_eval judges it
    (post-synth-audit fix round, 2026-10-07)."""
    with open(os.path.join(HERE, "jccard_post.tcl")) as f:
        return _build_card_text() + f.read()


def test_bscan_check_present():
    text = _census_text()
    assert "BSCANE2" in text
    assert "chain3" in text and "chain4" in text
    assert "get_debug_cores" in text
    assert "JCCARD_BSCAN_SUMMARY" in text
    assert "source $here/jccard_post.tcl" in _build_card_text()


def test_bscan_check_allows_exactly_one_hub_on_chain_1_only():
    # Revised 2026-10-07 (post-synth-audit.md WILL-FAIL 2): the debug cores are the hub
    # AND the JTAG-AXI cores, counted apart; the set is exact (one dbg_hub on chain 1,
    # one jtag_hbm). The behaviour is tested by test_jccard_post.py's census test, which
    # runs build_card.tcl's own census procs; this only pins the shape of the rule.
    text = _census_text()
    assert re.search(r"\$nhub\s*==\s*1\s*&&\s*\$nhub_chain1\s*==\s*1", text)
    assert re.search(r"\$njtagaxi\s*==\s*1\s*&&\s*\$njtag_hbm\s*==\s*1", text)
    # the old all-or-nothing refusal must be gone from the actual CHECK (it may
    # still be named in an explanatory comment about what was wrong with it)
    for line in text.splitlines():
        if "||" in line or "jcc_fail" in line:
            assert not re.search(r"\$nhub\s*!=\s*0\b", line)


def test_bscan_census_runs_after_opt_design_and_before_bitstream():
    text = _build_card_text()
    assert "jccard_bscan_check post_opt_design" in text
    assert "jccard_bscan_check pre_write_bitstream" in text
    assert text.index("jccard_bscan_check post_opt_design") < text.index("place_design")
    assert text.index("jccard_bscan_check pre_write_bitstream") < text.index("write_bitstream -force")


def test_readme_no_longer_claims_no_debug_hub():
    with open(os.path.join(HERE, "README.md")) as f:
        readme = f.read()
    assert "no debug hub on either chain" not in readme
    assert "chain 1" in readme


# ---- build_card.tcl: WNS / WHS gate --------------------------------------------------

def test_wns_refusal_unless_allow_neg():
    text = _build_card_text()
    assert "allow_neg" in text
    assert re.search(r"wns\s*<\s*0", text)


def test_whs_never_waived():
    text = _build_card_text()
    assert re.search(r"whs\s*<\s*0", text)
    assert "never waived by allow_neg" in text


# ---- build_card.tcl: documented concerns this task cannot close --------------------

def test_cattrip_treated_as_asynchronous():
    text = _build_card_text()
    assert "set_false_path" in text
    assert "halt_or" in text


# ---- 2026-10-07: --clk-mhz (the 27B composition routes at 134.6 MHz, jcooc27_2) ----

def test_dry_run_default_clock_reaches_tclargs_as_200(tmp_path):
    r = _dry_run(str(tmp_path / "root"))
    assert re.search(r"-tclargs\b.*\s-clk_mhz 200\b", r.stdout), r.stdout


def test_dry_run_clk_mhz_option_sets_every_consumer(tmp_path):
    r = _dry_run(str(tmp_path / "root"), flags=["--clk-mhz", "125"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "clk_core_mhz=125" in r.stdout
    assert "JC_CLK_CORE_MHZ=125" in r.stdout
    assert "JC_CLK_CORE_MHZ=200" not in r.stdout
    assert re.search(r"-tclargs\b.*\s-clk_mhz 125\b", r.stdout), r.stdout


def test_clk_mhz_outside_range_or_non_integer_is_refused(tmp_path):
    for bad in ("49", "251", "12.5", "abc", ""):
        r = _dry_run(str(tmp_path / ("root_" + (bad or "empty"))), flags=["--clk-mhz", bad])
        assert r.returncode != 0, bad
        assert not os.path.exists(str(tmp_path / ("root_" + (bad or "empty"))))


def test_build_card_takes_the_clock_from_tclargs_not_a_constant():
    t = _build_card_text()
    assert re.search(r"lsearch -exact \$argv -clk_mhz", t)
    assert 'puts "JCCARD_CLK_CORE_MHZ $clk_mhz"' in t
    assert 'puts "JCCARD_CLK_CORE_MHZ 200"' not in t
    assert "abs($aclk_p - 5.0)" not in t
    assert re.search(r"1000\.0\s*/\s*\$clk_mhz", t)


def test_netlist_cell_check_is_anchored_on_the_bd_ip_ref_name():
    # jccard1 (2026-10-07) failed "cell eng not found (2)": fk33_engine.vhd has its own
    # inner instance named `eng` (matvec_int4_desc_axi), so NAME =~ "*/eng" alone matches
    # the BD cell AND A's matvec. The BD's module-reference cells are IPs named
    # jcc_<cell>_0; anchor on that REF_NAME.
    t = _build_card_text()
    line = [l for l in t.splitlines() if "set c [get_cells" in l and "EXPECT" not in l and "$cname" in l]
    assert len(line) == 1, line
    assert 'REF_NAME == jcc_${cname}_0' in line[0], line[0]


def test_netlist_const_check_consults_the_exact_allowlist():
    t = _build_card_text()
    assert "source $repo/hw/jc/card/jccard_const_allow.tcl" in t
    assert re.search(r"if \{\(\$t eq \"GROUND\" \|\| \$t eq \"POWER\"\) && !\[jcc_const_allowed \$pin \$t\]\}", t), \
        "a constant input must be refused unless jcc_const_allowed accepts that exact pin and polarity"
    assert "JCCARD_NETLIST_INPUTS checked=$total_nin allowed_const=$total_allowed constant_or_open=[llength $total_bad]" in t


def test_ip_synthesis_runs_at_most_two_jobs():
    # jccard3 (2026-10-07): -jobs 4 overlapped the heavy IP syntheses and drove the box to
    # 0.44 GB SwapFree before the system guard stopped it; jccard1/2 peaked at ~19 GB unit swap.
    t = _build_card_text()
    assert re.findall(r"launch_runs synth_1 -jobs (\d+)", t) == ["2"]


def test_every_synth_run_gets_the_helper_cap_and_it_is_verified():
    # jccard4 (2026-10-07): each IP synthesis forked up to 8 helper vivados ("Multithreading
    # enabled for synth_design using a maximum of 8 processes"); set_param in this process
    # does not reach launch_runs' children. Cap them through STEPS.SYNTH_DESIGN.TCL.PRE and
    # refuse if any run's log does not show the cap.
    t = _build_card_text()
    hook = os.path.join(HERE, "synth_threads_pre.tcl")
    assert os.path.exists(hook)
    with open(hook) as f:
        h = f.read()
    assert "set_param synth.maxThreads 2" in h and "set_param general.maxThreads 2" in h
    i_gen, i_hook, i_launch = (t.index("generate_target all [get_files jcc.bd]"),
                               t.index("STEPS.SYNTH_DESIGN.TCL.PRE"),
                               t.index("launch_runs synth_1"))
    assert i_gen < i_hook < i_launch
    assert "create_ip_run [get_files jcc.bd]" in t
    assert "maximum of 2 processes" in t[i_launch:]
    assert "JCCARD_SYNTH_HOOK" in t


def test_lever_trace_is_gathered_from_every_synthesis_runs_vds():
    # jccard5 (2026-10-07): with module-reference cells synthesized out of context, the
    # card's bind lines are in jcc_card_0_synth_1/jcc_card_0.vds, not synth_1/<top>.vds.
    t = _build_card_text()
    i = t.index("source $here/jccard_levers.tcl")
    seg = t[i:i + 1500]
    assert "get_runs -filter {IS_SYNTHESIS}" in seg
    assert "*.vds" in seg
    assert "jcc_fail \"levers: no synthesis .vds" in seg
