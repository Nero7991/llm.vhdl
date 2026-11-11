"""hw/jc/card/test_jccard_post.py -- the post-synthesis audit fix round (2026-10-07,
.superpowers/sdd/2026-10-07-jc-engine-composition/post-synth-audit.md).

Wherever a gate can run without Vivado, the test runs build_card.tcl's OWN text (cut out
by marker and eval'd under plain tclsh, with the handful of Vivado commands it calls
replaced by stubs) against REAL captured Vivado reports, so the thing tested is the build
script, not a copy of its logic. The rest are static checks on the script text; the
netlist-level queries were validated on jccard5's synthesized design (see
post-synth-fix-report.md).

JCCARD_TEST_REV=<rev> runs the same tests against build_card.tcl / jccard_post.tcl /
jc_ctl_timing.tcl as they were at <rev> (`git show`), which is how RED was shown on the
pre-fix code: JCCARD_TEST_REV=4a909a05 python3 -m pytest hw/jc/card/test_jccard_post.py

    python3 -m pytest hw/jc/card/test_jccard_post.py -q
"""
import os
import re
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
DATA = os.path.join(HERE, "testdata")
LOADER_FULL = os.path.join(REPO, "hw", "jc", "loader", "results", "2026-10-05", "full")
BUS_LOADER = os.path.join(LOADER_FULL, "bus_skew.rpt")
CDC_LOADER = os.path.join(LOADER_FULL, "cdc.rpt")
BUS_CTL = os.path.join(DATA, "bus_skew_jcctl_ooc4.rpt")
BUS_CARD_SYNTH = os.path.join(DATA, "bus_skew_jccard5_synth.rpt")
# jccard_loop3's routed report_cdc (2026-11-11): two CDC-10 rows into tok's s_pll and s_tx
CDC_LOOP3 = os.path.join(DATA, "cdc_jccard_loop3_routed.rpt")
REV = os.environ.get("JCCARD_TEST_REV", "")


def _src(rel):
    """Repository file text at JCCARD_TEST_REV (or the working tree); None if absent."""
    if REV:
        r = subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (REV, rel)],
                           capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else None
    p = os.path.join(REPO, rel)
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return f.read()


def _build():
    return _src("hw/jc/card/build_card.tcl")


def _code_lines(text):
    return [l for l in text.splitlines() if not l.strip().startswith("#")]


def _seg(text, start, end):
    a = text.index(start)
    b = text.index(end, a)
    return text[a:b]


def _read(p):
    with open(p) as f:
        return f.read()


def _tcl_brace(s):
    """A short name as a Tcl braced word (names here hold [ ] but never braces)."""
    assert "{" not in s and "}" not in s
    return "{" + s + "}"


_NFIX = [0]


def _tcl_file(tmp_path, content):
    """A fixture as a Tcl expression that reads it back from a file (reports hold braces)."""
    _NFIX[0] += 1
    f = tmp_path / ("fix%d.txt" % _NFIX[0])
    f.write_text(content)
    return "[apply {{p} {set fh [open $p]; set t [read $fh]; close $fh; return $t}} {%s}]" % f


def _tclsh(script, tmp_path):
    f = tmp_path / "t.tcl"
    f.write_text(script)
    return subprocess.run(["tclsh", str(f)], capture_output=True, text=True)


def _post_prelude(tmp_path):
    """Source jccard_post.tcl (as of REV) if it exists, as build_card.tcl does at its top."""
    post = _src("hw/jc/card/jccard_post.tcl")
    if post is None:
        return ""
    p = tmp_path / "jccard_post.tcl"
    p.write_text(post)
    return "source {%s}\n" % p


JCC_FAIL = 'proc jcc_fail {msg} { puts "JCCARD_FAIL $msg"; exit 1 }\n'
CORES = 'set CORE_LOADER "*u_jc_core/"\nset CORE_CTL "*/jcc_i/ctl/inst/"\nset CORE_TOK "*/jcc_i/tok/inst/"\n'


# ---- WILL-FAIL 1: the halt_or output pin ---------------------------------------------
# Validated on jccard5 synth_1 (post-synth-fix-report.md): `*halt_or*/Res` -> 0;
# `*/jcc_i/halt_or/Res*` && DIRECTION == OUT -> 2 (Res[0] and Res[0]_INST_0/O); the
# output pins of the hierarchical cell -> exactly u_bd/jcc_i/halt_or/Res[0].

def test_halt_or_pin_is_the_hierarchical_cells_one_output():
    code = "\n".join(_code_lines(_build()))
    assert '*halt_or*/Res"' not in code
    assert re.search(r'set halt_cell \[get_cells -quiet -hierarchical -filter '
                     r'\{NAME =~ "\*/jcc_i/halt_or" && IS_PRIMITIVE == 0\}\]', code)
    assert re.search(r'set halt_src \[get_pins -quiet -of_objects \$halt_cell '
                     r'-filter \{DIRECTION == OUT\}\]', code)
    assert re.search(r'llength \$halt_cell\] != 1', code)
    assert re.search(r'llength \$halt_src\] != 1', code)


# ---- PASS-WRONGLY 3 (MEASURED: in fact ERROR Constraints 18-513): the false path -------

HALT_STUBS = r'''
set ::FP {}
proc get_cells {args} { return u_bd/jcc_i/halt_or }
proc get_pins {args} { return {u_bd/jcc_i/halt_or/Res[0]} }
proc set_false_path {args} { lappend ::FP $args }
proc get_timing_paths {args} {
  if {[lsearch -exact [join $::FP] -through] < 0} { return $::PATHS_NOEXC }
  return $::PATHS
}
proc get_property {prop obj} { return [dict get $obj $prop] }
'''


def _halt_run(tmp_path, paths, noexc=None):
    seg = _seg(_build(), "  set halt_cell [get_cells", '  puts "JCCARD_CATTRIP_FALSE_PATH')
    p = lambda ps: "[list " + " ".join(
        "[dict create ENDPOINT_PIN %s EXCEPTION %s]" % (_tcl_brace(e), _tcl_brace(x))
        for e, x in ps) + "]"
    script = (HALT_STUBS + "set ::PATHS %s\nset ::PATHS_NOEXC %s\n" % (p(paths), p(noexc or paths))
              + "if {[catch {\n" + seg + "} err]} { puts \"ERR $err\"; exit 1 }\n"
              + "puts \"FP $::FP\"\nputs OK\n")
    return _tclsh(script, tmp_path)


def test_cattrip_false_path_is_through_and_must_be_seen_to_land(tmp_path):
    code = _code_lines(_build())
    assert not any(re.search(r"set_false_path\s+-from\s+\$halt_src", l) for l in code)
    # landed: every path through the pin is a false path, and there is at least one
    ep = "u_bd/jcc_i/card/inst/u/ga_desc.u_ad/st_reg[0]/CE"
    r = _halt_run(tmp_path, [(ep, "False Path"), ("u_bd/jcc_i/eng/inst/xrdata_reg[2]/D", "False Path")],
                  noexc=[(ep, "")])
    assert r.returncode == 0 and "OK" in r.stdout, r.stdout + r.stderr
    assert "-through {u_bd/jcc_i/halt_or/Res[0]}" in r.stdout
    # teeth: a path still timed, or no path at all, refuses
    r = _halt_run(tmp_path, [(ep, "False Path"), ("u_bd/jcc_i/eng/inst/x_reg/D", "")])
    assert r.returncode == 1 and "did not land" in r.stdout, r.stdout
    r = _halt_run(tmp_path, [])
    assert r.returncode == 1 and "did not land" in r.stdout, r.stdout


# ---- WILL-FAIL 2: the BSCAN / debug-core census ---------------------------------------
# Names MEASURED: card synth_1 cores dbg_hub (C_USER_SCAN_CHAIN listed) and
# u_bd/jcc_i/jtag_hbm (not listed); BSCANE2 u_bd/jcc_i/loader/inst/u_jc_frx/u_jc_bscan
# (4) and u_jc_ctl_rx/u_jc_ctl_bscan (3); the hub's BSCANE2 name from the loader's routed
# full4 (chain 1).

HUB_BSCAN = "dbg_hub/inst/BSCANID.u_xsdbm_id/SWITCH_N_EXT_BSCAN.bscan_inst/SERIES7_BSCAN.bscan_inst"
CARD_BSCANS = [(HUB_BSCAN, 1), ("u_bd/jcc_i/loader/inst/u_jc_frx/u_jc_bscan", 4),
               ("u_jc_ctl_rx/u_jc_ctl_bscan", 3)]
CARD_CORES = [("dbg_hub", "1"), ("u_bd/jcc_i/jtag_hbm", "")]

CENSUS_STUBS = r'''
proc get_cells {args} { return [dict keys $::B] }
proc get_debug_cores {args} { return [dict keys $::D] }
proc list_property {o p} { if {[dict exists $::D $o] && [dict get $::D $o] ne ""} { return $p }; return {} }
proc get_property {p o} {
  switch -- $p { NAME { return $o } JTAG_CHAIN { return [dict get $::B $o] } C_USER_SCAN_CHAIN { return [dict get $::D $o] } }
  error "stub: $p"
}
'''


def _census(tmp_path, bscans, cores):
    seg = _seg(_build(), "proc jccard_bscan_census {} {", "create_project -force jc_card")
    b = " ".join("%s %s" % (_tcl_brace(n), c) for n, c in bscans)
    d = " ".join("%s %s" % (_tcl_brace(n), _tcl_brace(c)) for n, c in cores)
    script = (JCC_FAIL + _post_prelude(tmp_path) + CENSUS_STUBS
              + "set ::B [dict create %s]\nset ::D [dict create %s]\n" % (b, d)
              + seg + "\njccard_bscan_check post_opt_design\n")
    r = _tclsh(script, tmp_path)
    return r.returncode == 0 and "JCCARD_BSCAN_OK post_opt_design" in r.stdout, r


def test_census_accepts_exactly_the_cards_set_and_refuses_every_other(tmp_path):
    ok, r = _census(tmp_path, CARD_BSCANS, CARD_CORES)
    assert ok, r.stdout + r.stderr
    refused = {
        "loader's set: two JTAG-AXI cores": (CARD_BSCANS, CARD_CORES + [("u_bd/jcc_i/jtag_axi_0", "")]),
        "no jtag_hbm": (CARD_BSCANS, [("dbg_hub", "1")]),
        "a JTAG-AXI core that is not jtag_hbm": (CARD_BSCANS, [("dbg_hub", "1"), ("u_bd/jcc_i/other_axi", "")]),
        "hub on chain 2": (CARD_BSCANS, [("dbg_hub", "2"), ("u_bd/jcc_i/jtag_hbm", "")]),
        "two hubs": (CARD_BSCANS, CARD_CORES + [("dbg_hub_1", "1")]),
        "no hub": (CARD_BSCANS, [("u_bd/jcc_i/jtag_hbm", "")]),
        "extra BSCANE2 on chain 2": (CARD_BSCANS + [("u_bd/jcc_i/eng/x_bscan", 2)], CARD_CORES),
        "ctl BSCANE2 missing": (CARD_BSCANS[:2], CARD_CORES),
        "chain 4 not the loader's": ([CARD_BSCANS[0], ("u_bd/jcc_i/eng/u_jc_bscan", 4), CARD_BSCANS[2]], CARD_CORES),
    }
    for name, (b, d) in refused.items():
        ok, r = _census(tmp_path, b, d)
        assert not ok, name
        assert "JCCARD_FAIL bscan census (post_opt_design)" in r.stdout, name


# ---- PASS-WRONGLY 4 and 6: the post-route report section, run verbatim -----------------

REPORT_STUBS = r'''
proc _rep {name args} {
  set txt ""
  if {$name eq "report_bus_skew"} { set txt $::BUS }
  if {$name eq "report_cdc" && [lsearch -exact $args -details] >= 0} { set txt $::CDC }
  set i [lsearch -exact $args -file]
  if {$i >= 0} { set fh [open [lindex $args [expr {$i + 1}]] w]; puts -nonewline $fh $txt; close $fh; return }
  return $txt
}
foreach n {report_route_status report_utilization report_timing_summary report_clock_interaction
           report_clocks report_cdc report_exceptions report_bus_skew report_methodology
           report_drc report_pulse_width check_timing} { proc $n {args} "_rep $n {*}\$args" }
'''


def _reports(tmp_path, bus, cdc):
    seg = _seg(_build(), "set rp $bd/reports", "set rs [report_route_status -return_string]")
    script = (JCC_FAIL + _post_prelude(tmp_path) + CORES + REPORT_STUBS
              + "set bd {%s}\nset ::BUS %s\nset ::CDC %s\n" % (tmp_path, _tcl_file(tmp_path, bus), _tcl_file(tmp_path, cdc))
              + seg + "\nputs REPORTS_PASSED\n")
    r = _tclsh(script, tmp_path)
    return r.returncode == 0 and "REPORTS_PASSED" in r.stdout, r


def _neg_slack(bus):
    """The first summary row's slack (4.467, MEASURED) made negative."""
    assert "0.533      4.467" in bus
    return bus.replace("0.533      4.467", "5.120     -0.120", 1)


def test_bus_skew_is_gated_on_the_real_report(tmp_path):
    bus, cdc = _read(BUS_LOADER), _read(CDC_LOADER)
    # teeth: one negative slack, a constraint whose numbers did not parse, no constraints
    for name, mutant in {
        "negative slack": _neg_slack(bus),
        "unparsed row": bus.replace("Slow              5.000       0.533      4.467", "Slow              5.000       0.533", 1),
        "empty report": "",
    }.items():
        ok, r = _reports(tmp_path, mutant, cdc)
        assert not ok and "JCCARD_FAIL bus skew" in r.stdout, name + ": " + r.stdout
    ok, r = _reports(tmp_path, bus, cdc)
    assert ok, r.stdout + r.stderr
    assert "JCCARD_BUS_SKEW constraints=22 rows=22 violated=0 worst=4.327" in r.stdout, r.stdout


def _post_tcl(tmp_path, body):
    script = _post_prelude(tmp_path) + body
    return _tclsh(script, tmp_path)


def test_bus_skew_parser_on_three_real_reports(tmp_path):
    body = "".join(
        "set fh [open {%s}]; puts \"%s [jccard_bus_skew_parse [read $fh]]\"; close $fh\n" % (p, tag)
        for tag, p in (("LOADER", BUS_LOADER), ("CTL", BUS_CTL), ("CARD", BUS_CARD_SYNTH)))
    r = _post_tcl(tmp_path, body)
    assert r.returncode == 0, r.stderr
    # loader full4 (routed): 22 constraints (2 own + 8 + 8 jtag_axi FIFOs + 4 dbg_hub)
    assert "LOADER 22 22 0 4.327 0" in r.stdout, r.stdout
    # ctl OOC (routed): 2 constraints, short names
    assert "CTL 2 2 0 4.605 0" in r.stdout, r.stdout
    # the card itself (jccard5, synthesized): 12 constraints, the 8 jtag_hbm XPM ones NA
    assert "CARD 12 4 0 7.580 8" in r.stdout, r.stdout


def test_bus_skew_gate_refuses_constraints_without_paths(tmp_path):
    """The card's real synthesized report has 8 NA (no-path) constraints: the gate, run
    verbatim, must refuse it rather than count only the 4 rows that have numbers."""
    ok, r = _reports(tmp_path, _read(BUS_CARD_SYNTH), _read(CDC_LOADER))
    assert not ok and "JCCARD_FAIL bus skew: constraints=12 rows=4" in r.stdout, r.stdout
    assert "no_paths=8" in r.stdout, r.stdout


CRIT_SUMMARY = "CDC-1   Critical      %d  1-bit unknown CDC circuitry\n"
# a detail row in the exact column layout of the loader's real report (tck_user4 ->
# aclk table, row 3), severity made Critical, destination substituted
ROW = ("  9  CDC-1  Critical  1-bit unknown CDC circuitry                       0  None                     "
       "u_bd/jcc_i/loader/inst/u_jc_core/sync/ack_reg/C        %s")


def _cdc_with(rows):
    cdc = _read(CDC_LOADER)
    head = "CDC-3   Info         14  1-bit synchronized with ASYNC_REG property\n"
    assert head in cdc
    cdc = cdc.replace(head, (CRIT_SUMMARY % len(rows)) + head, 1)
    anchor = "  3  CDC-3  Info      1-bit synchronized with ASYNC_REG property          2  Max Delay Datapath Only  jcl_i/loader/inst/u_jc_core/sync/ack_reg/C        jcl_i/loader/inst/u_jc_core/sync/ack_s1_reg/D\n"
    assert anchor in cdc
    return cdc.replace(anchor, anchor + "".join(ROW % d + "\n" for d in rows), 1)


def test_report_cdc_critical_rows_are_judged_by_destination_only(tmp_path):
    bus = _read(BUS_LOADER)
    # a Critical crossing INTO a named synchroniser's first stage is allowed
    ok, r = _reports(tmp_path, bus, _cdc_with(["u_bd/jcc_i/loader/inst/u_jc_core/sync/ack_s1_reg/D",
                                               "u_bd/jcc_i/ctl/inst/rak_s1_reg/D"]))
    assert ok and "summary=2 rows=2 unknown=0" in r.stdout, r.stdout
    ok, r = _reports(tmp_path, bus, _read(CDC_LOADER))
    assert ok and "JCCARD_CDC_REPORT_CRITICAL summary=0 rows=0 unknown=0" in r.stdout, r.stdout
    refused = {
        # source is a synchroniser register, destination is not: the old scan passed it
        "source-only match": _cdc_with(["u_bd/jcc_i/eng/inst/eng/halt_q_reg/D"]),
        # engctl (a smartconnect) shares "ctl/inst/": the anchored prefix refuses it
        "engctl is not ctl": _cdc_with(["u_bd/jcc_i/engctl/inst/rak_s1_reg/D"]),
        # the summary says 2, one row parsed
        "row count mismatch": _cdc_with(["u_bd/jcc_i/ctl/inst/rak_s1_reg/D"]).replace(
            CRIT_SUMMARY % 1, CRIT_SUMMARY % 2, 1),
    }
    for name, cdc in refused.items():
        ok, r = _reports(tmp_path, bus, cdc)
        assert not ok and "JCCARD_FAIL report_cdc" in r.stdout, name + ": " + r.stdout


LOOP3_PLL = ("u_bd/jcc_i/aur/inst/jcc_aur_0_core_i/jcc_aur_0_wrapper_i/u_cdc_tx_fsm_resetdone_i/"
             "s_level_out_d5_reg/C  u_bd/jcc_i/tok/inst/s_pll_reg[0]/D")
LOOP3_TX = ("u_bd/jcc_i/aur/inst/jcc_aur_0_core_i/simplex_tx_global_logic_i/simplex_tx_channel_init_sm_i/"
            "counter2_r_reg[1]/C  u_bd/jcc_i/tok/inst/s_tx_reg[0]/D")


def _loop3_rows(cdc):
    """The two CDC-10 detail lines of the real loop3 report, by their source/destination."""
    rows = [l for l in cdc.split("\n") if "CDC-10  Critical" in l and not l.startswith("CDC-10")]
    assert len(rows) == 2 and any(LOOP3_PLL in l for l in rows) and any(LOOP3_TX in l for l in rows), rows
    return rows


def test_report_cdc_refuses_loop3_cdc10_by_name(tmp_path):
    """jccard_loop3's real report: both CDC-10 rows land on tok synchronisers the gate now
    names, and the gate refuses them AS NAMED (not as unknown destinations)."""
    bus, cdc = _read(BUS_LOADER), _read(CDC_LOOP3)
    rows = _loop3_rows(cdc)
    ok, r = _reports(tmp_path, bus, cdc)
    assert not ok, r.stdout
    assert "summary=2 rows=2 unknown=0 named=2 named_refused=2" in r.stdout, r.stdout
    assert "JCCARD_FAIL report_cdc: 2 critical crossing(s) at a named synchroniser" in r.stdout, r.stdout
    assert "JCCARD_CDC_REPORT_NAMED REFUSED CDC-10 at */jcc_i/tok/inst/s_pll_reg*" in r.stdout, r.stdout
    assert "JCCARD_CDC_REPORT_NAMED REFUSED CDC-10 at */jcc_i/tok/inst/s_tx_reg*" in r.stdout, r.stdout
    assert "JCCARD_CDC_REPORT_UNKNOWN" not in r.stdout, r.stdout
    # the same two rows as another Critical rule at the same named synchronisers: allowed
    # (so the refusal above is the CDC-10 rule, not the destination)
    c1 = cdc.replace("CDC-10  Critical      2  Combinational", "CDC-1   Critical      2  Combinational", 1)
    for l in rows:
        c1 = c1.replace(l, l.replace("CDC-10  Critical", "CDC-1   Critical", 1), 1)
    ok, r = _reports(tmp_path, bus, c1)
    assert ok and "summary=2 rows=2 unknown=0 named=2 named_refused=0" in r.stdout, r.stdout
    # the fixed state (no Critical rows): passes
    c0 = cdc.replace("CDC-10  Critical      2  Combinational", "CDC-10  Critical      0  Combinational", 1)
    for l in rows:
        c0 = c0.replace(l + "\n", "", 1)
    ok, r = _reports(tmp_path, bus, c0)
    assert ok and "summary=0 rows=0 unknown=0 named=0 named_refused=0" in r.stdout, r.stdout
    # teeth: a CDC-10 into a tok register that is NOT a named synchroniser is still unknown
    cx = cdc.replace("tok/inst/s_tx_reg[0]/D", "tok/inst/u_txup_reg/D", 1)
    ok, r = _reports(tmp_path, bus, cx)
    assert not ok and "unknown=1 named=1 named_refused=1" in r.stdout, r.stdout


# ---- PASS-WRONGLY 5: jctl_syncs in the card flow ---------------------------------------

def test_jctl_syncs_runs_in_the_card_flow_before_opt_design():
    text = _build()
    code = "\n".join(_code_lines(text))
    assert re.search(r"^\s*jctl_syncs \$CORE_CTL\s*$", code, re.M)
    i = code.index("jctl_syncs $CORE_CTL")
    first_opt = re.search(r"^\s*opt_design\b", code, re.M).start()
    assert code.index("open_run synth_1") < i < first_opt
    # inside the constraints catch, so a JCCTL_SYNC error becomes JCCARD_FAIL
    block = _seg(code, "if {[catch {", '} err]} { jcc_fail "constraints: $err" }')
    assert "jctl_syncs $CORE_CTL" in block


def test_ctl_consumer_trace_accepts_the_card_netlist(tmp_path):
    """hw/jc/ctl/test_jc_ctl_timing.tcl (the mock-netlist unit check) with the card's
    measured shape (rak_s2 -> a top-level s_rvalid LUT feeding ex/), run against
    jc_ctl_timing.tcl as of REV."""
    d = tmp_path / "ctl"
    d.mkdir()
    shutil.copy(os.path.join(REPO, "hw", "jc", "ctl", "test_jc_ctl_timing.tcl"), d)
    (d / "jc_ctl_timing.tcl").write_text(_src("hw/jc/ctl/jc_ctl_timing.tcl"))
    r = subprocess.run(["tclsh", str(d / "test_jc_ctl_timing.tcl")], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout[-3000:]
    assert "JCCTL_TCLTEST_PASS 13 FAIL 0" in r.stdout


def test_ctl_fifo_clear_ack_crossing_is_constrained_and_audited():
    """Found by this round's validation (not one of the six): the card's IP synthesis keeps
    the ctl FIFO's clear-acknowledge chain (KEEP on every ASYNC_REG flop), so
    fifo/clr_ack_r (aclk) -> fifo/clr_a_s1_reg (tck) is a real crossing, and the ctl audit
    printed JCCTL_CDC_UNEXPECTED a2t u_bd/jcc_i/ctl/inst/fifo/clr_a_s1_reg/D (jccard5)."""
    t = _src("hw/jc/ctl/jc_ctl_timing.tcl")
    cdc = t[t.index("proc jctl_cdc {"):t.index("proc jctl_cdc_audit")]
    assert re.search(r'fifo/clr_a_s1_reg', cdc)
    assert re.search(r'set_max_delay -datapath_only \$aclk_p -from \$clk_a -to \$ca', cdc)
    audit = t[t.index("proc jctl_cdc_audit"):t.index("proc jctl_we_live")]
    ok_at = audit[audit.index("set ok_at"):audit.index("set ok_ta")]
    assert '"${core}fifo/clr_a_s1_reg"' in ok_at
    syncs = t[t.index("proc jctl_syncs"):t.index("proc jctl_tdi")]
    assert 'jctl_sync_chain "${core}fifo/clr_a_s1_reg" "${core}fifo/clr_a_s2_reg"' in syncs


AUDIT_STUBS = r'''
proc get_timing_paths {args} {
  set from [lindex $args [expr {[lsearch -exact $args -from] + 1}]]
  if {$from eq "A"} { return $::A2T }
  return $::T2A
}
proc get_property {p o} { return $o }
proc get_pins {p} { return $p }
proc get_cells {args} { return [join [lrange [split [lindex $args end] /] 0 end-1] /] }
'''


def _audit(tmp_path, a2t, t2a):
    t = tmp_path / "jc_ctl_timing.tcl"
    t.write_text(_src("hw/jc/ctl/jc_ctl_timing.tcl"))
    lst = lambda ps: "[list " + " ".join(_tcl_brace(x) for x in ps) + "]"
    script = (AUDIT_STUBS + "source {%s}\nset ::A2T %s\nset ::T2A %s\n" % (t, lst(a2t), lst(t2a))
              + 'puts "BAD [jctl_cdc_audit {*/jcc_i/ctl/inst/} A T]"\n')
    return _tclsh(script, tmp_path)


def test_ctl_cdc_audit_runs_and_names_the_clear_ack(tmp_path):
    """jctl_cdc_audit EXECUTED (stubbed paths), not grepped: the jccard5 endpoint list
    with the clear-ack crossing must count 0, and an unnamed endpoint must still count."""
    pre = "u_bd/jcc_i/ctl/inst/"
    a2t = [pre + "sync/st_r_reg[5]/D", pre + "sync/tgl_s1_reg/D", pre + "fifo/rp_g_s1_reg[3]/D",
           pre + "fifo/clr_a_s1_reg/D"]
    t2a = [pre + "sync/ack_s1_reg/D", pre + "rak_s1_reg/D", pre + "fifo/wp_g_s1_reg[0]/D"]
    r = _audit(tmp_path, a2t, t2a)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "BAD 0" in r.stdout, r.stdout
    r = _audit(tmp_path, a2t + [pre + "ex/s_rvalid_reg/D"], t2a + ["u_bd/jcc_i/engctl/inst/rak_s1_reg/D"])
    assert r.returncode == 0 and "BAD 2" in r.stdout, r.stdout + r.stderr


# ---- minor: CORE_CTL anchored ---------------------------------------------------------

def test_core_ctl_is_anchored_on_the_bd_cell():
    code = "\n".join(_code_lines(_build()))
    assert re.search(r'^set CORE_CTL\s+"\*/jcc_i/ctl/inst/"\s*$', code, re.M)
