"""hw/jc/card/test_run_card.py -- Task 9. Dry-run assertions on run_card.sh (the
orchestration) and static assertions on build_card.tcl (the Vivado flow it calls).
No Vivado, no git side effects, no hardware: `run_card.sh --dry-run` only prints the
commands and parameter bindings it would use.

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


def _dry_run(root, extra=()):
    r = subprocess.run(["bash", RUN_CARD, "--dry-run", root, *extra],
                        cwd=REPO, capture_output=True, text=True)
    return r


def _build_card_text():
    with open(BUILD_CARD) as f:
        return f.read()


def _run_card_text():
    with open(RUN_CARD) as f:
        return f.read()


# ---- run_card.sh --dry-run ---------------------------------------------------------

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


def test_dry_run_part_overridable(tmp_path):
    r = _dry_run(str(tmp_path / "root"), extra=["xcvu35p-fsvh2104-1-e"])
    assert "xcvu35p-fsvh2104-1-e" in r.stdout
    assert "-tclargs" in r.stdout


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


# ---- run_card.sh: the sentinel is anchored, read from Vivado's own log -------------

def test_sentinel_grep_is_anchored():
    text = _run_card_text()
    assert re.search(r"grep\s+-qE\s+'\^JCCARD_DONE'", text)
    assert re.search(r"grep\s+-E\s+'\^JCCARD_FAIL'", text)


def test_sentinel_not_gated_on_exit_code_alone():
    text = _run_card_text()
    # the log line, not $RC, decides SENTINEL_OK
    assert "SENTINEL_OK" in text
    assert "$BUILD_LOG" in text


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


# ---- build_card.tcl: the lever check -----------------------------------------------

def test_lever_check_present():
    text = _build_card_text()
    for lever in ("NWIDE", "SWEEP_PIPE", "SCORE_EARLY"):
        assert lever in text
    assert "bound to" in text
    assert "JCCARD_LEVERS_OK" in text


def test_lever_check_refuses_on_missing_bind_line():
    text = _build_card_text()
    assert "no bind line found" in text


# ---- build_card.tcl: the BSCAN check ------------------------------------------------

def test_bscan_check_present():
    text = _build_card_text()
    assert "BSCANE2" in text
    assert "chain3" in text and "chain4" in text
    assert "get_debug_cores" in text
    assert "JCCARD_BSCAN_SUMMARY" in text


def test_bscan_check_refuses_on_debug_hub():
    text = _build_card_text()
    assert re.search(r"debug_hub\s*!=\s*0", text) or "nhub != 0" in text


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
