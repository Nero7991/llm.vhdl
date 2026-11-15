# hw/jc/card/jccard_post.tcl -- the PURE (no Vivado object) halves of build_card.tcl's
# post-synthesis and post-route gates, so each can be tested stand-alone in tclsh against
# real captured data (test_jccard_post.py). build_card.tcl gathers the objects/reports
# and calls these; nothing here queries a design.
#
# Fix round of 2026-10-07 (.superpowers/sdd/2026-10-07-jc-engine-composition/
# post-synth-audit.md): WILL-FAIL 2 (BSCAN/debug-core census), PASS-WRONGLY 4 (bus skew
# never gated) and PASS-WRONGLY 6 (CDC report whitelist matched anywhere in the row).

# ---- BSCAN / debug-core census ------------------------------------------------------
# bscans: list of {cell_name JTAG_CHAIN}.
# cores:  list of {core_name chain}, chain = C_USER_SCAN_CHAIN, or "" when the core has no
#         such property. MEASURED (jc_loader full4 vivado.log:1987-1989, and re-read on
#         jcl_routed.dcp in this fix round): get_debug_cores returns the debug HUB
#         (dbg_hub, the only core carrying C_USER_SCAN_CHAIN) AND every JTAG-AXI core
#         (jtag_axi_0, jtag_hbm: no C_USER_SCAN_CHAIN). The old census counted every core
#         as a hub, so the card's {dbg_hub, u_bd/jcc_i/jtag_hbm} read as two hubs and was
#         refused. Hubs and JTAG-AXI cores are now counted apart.
# The expected set, exactly: one BSCANE2 on chain 1 (the hub's), one on chain 3
# (*u_jc_ctl_rx/u_jc_ctl_bscan), one on chain 4 (*u_jc_frx/u_jc_bscan), none elsewhere;
# one hub, named dbg_hub, on user chain 1; one JTAG-AXI core, */jcc_i/jtag_hbm.
# Returns {ok summary}: ok 1 or 0, summary the k=v line build_card.tcl prints.
proc jccard_census_eval {bscans cores} {
  set n1 0; set n3 0; set n3ours 0; set n4 0; set n4ours 0; set nall 0
  foreach b $bscans {
    lassign $b c ch
    incr nall
    if {$ch == 1} { incr n1 }
    if {$ch == 3} { incr n3; if {[string match "*u_jc_ctl_rx/u_jc_ctl_bscan" $c]} { incr n3ours } }
    if {$ch == 4} { incr n4; if {[string match "*u_jc_frx/u_jc_bscan" $c]} { incr n4ours } }
  }
  set nhub 0; set nhub_chain1 0; set nhub_named 0; set njtagaxi 0; set njtag_hbm 0
  foreach d $cores {
    lassign $d name chv
    if {$chv ne ""} {
      incr nhub
      if {$chv == 1} { incr nhub_chain1 }
      if {$name eq "dbg_hub"} { incr nhub_named }
    } else {
      incr njtagaxi
      if {[string match "*/jcc_i/jtag_hbm" $name]} { incr njtag_hbm }
    }
  }
  set summary "total=$nall chain1=$n1 chain3=$n3 chain3_ctl=$n3ours chain4=$n4 chain4_loader=$n4ours debug_hub=$nhub debug_hub_chain1=$nhub_chain1 debug_hub_named=$nhub_named jtag_axi=$njtagaxi jtag_axi_hbm=$njtag_hbm"
  set ok [expr {$nall == 3 && $n1 == 1 && $n3 == 1 && $n3ours == 1 && $n4 == 1 && $n4ours == 1
                && $nhub == 1 && $nhub_chain1 == 1 && $nhub_named == 1
                && $njtagaxi == 1 && $njtag_hbm == 1}]
  return [list $ok $summary]
}

# ---- report_bus_skew ------------------------------------------------------------------
# Parses section 1 ("Bus Skew Report Summary") of a report_bus_skew text. Each constraint
# is an Id row (`<Id>  <Position>  <From...>`), and its numbers are on that row or on a
# continuation row ending `<Corner>  <Requirement>  <Actual>  <Slack>` (long From/To names
# wrap: MEASURED, hw/jc/loader/results/2026-10-05/full/bus_skew.rpt). A constraint with
# no paths reads `NA  <Requirement>  NA  NA` ("No bus skew paths found": MEASURED on
# jccard5's synthesized design, where the jtag_hbm XPM FIFOs' TCK does not exist until
# opt_design inserts dbg_hub; testdata/bus_skew_jccard5_synth.rpt). Returns
# {nids nrows nneg worst nna}: constraint rows, number rows, rows with negative slack,
# the worst slack seen ("" if none) and the NA rows. The caller requires nids >= its
# floor, nrows == nids (an Id whose numbers did not parse, or an NA, is a refusal: a
# constraint with no paths checks nothing) and nneg == 0.
proc jccard_bus_skew_parse {txt} {
  set in 0; set nids 0; set nrows 0; set nneg 0; set worst ""; set nna 0
  foreach l [split $txt "\n"] {
    if {!$in} {
      if {[regexp {^Id\s+Position\s+From\s} $l]} { set in 1 }
      continue
    }
    if {[regexp {^2\.\s+Bus Skew Report Per Constraint} $l]} { break }
    if {[regexp {^\d+\s+\d+\s+\S} $l]} { incr nids }
    if {[regexp {(Slow|Fast)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s*$} $l -> c req act s]} {
      incr nrows
      if {$s < 0} { incr nneg }
      if {$worst eq "" || $s < $worst} { set worst $s }
    }
    if {[regexp {\sNA\s+[0-9.]+\s+NA\s+NA\s*$} $l]} { incr nna }
  }
  return [list $nids $nrows $nneg $worst $nna]
}

# ---- report_cdc -details --------------------------------------------------------------
# A Critical crossing is allowed ONLY by its DESTINATION (the last column of a detail row,
# `Row ID Severity Description Depth Exception Source(From) Destination(To)`, columns
# separated by two or more spaces: MEASURED, hw/jc/loader/results/2026-10-05/full/cdc.rpt).
# The old scan whitelisted a LINE when a known name appeared anywhere in it, Source column
# included. (MEASURED in this fix round: on a real report it also tripped over the
# report's own summary-table row, `CDC-1  Critical  <n>  ...`, which names no
# synchroniser, so in practice it refused EVERY Critical crossing, named or not; the
# Source-column hole was real for a detail row but masked by that.)
# dst_ok: glob patterns a destination pin must match. refuse_ids: the CDC rule IDs refused
# even at a named synchroniser (default CDC-10, "Combinational logic detected before a
# synchronizer": the synchroniser is right and its INPUT is wrong, a glitch it can capture;
# MEASURED jccard_loop3, two of them into tok's s_pll/s_tx). Returns {nsum nrows bad named}:
# the Critical count the report's own summary table claims, the Critical detail rows parsed,
# the rows whose destination matched nothing, and the rows at a named synchroniser, each
# {verdict id pattern row} with verdict "allowed" or "refused". The caller requires nrows ==
# nsum (a row the parse missed is a refusal), bad empty and no "refused" entry in named.
proc jccard_cdc_scan {txt dst_ok {refuse_ids {CDC-10}}} {
  set nsum 0; set nrows 0; set bad {}; set named {}
  foreach l [split $txt "\n"] {
    if {[regexp {^(CDC-\d+)\s+Critical\s+(\d+)\s} $l -> id cnt]} { incr nsum $cnt; continue }
    if {![regexp {^\s*\d+\s+(CDC-\d+)\s+Critical\s} $l -> id]} { continue }
    incr nrows
    set f [regexp -all -inline {\S+(?: \S+)*} [string trim $l]]
    set dst [lindex $f end]
    set hit ""
    foreach p $dst_ok { if {[string match $p $dst]} { set hit $p; break } }
    if {$hit eq ""} { lappend bad $l; continue }
    set v [expr {[lsearch -exact $refuse_ids $id] >= 0 ? "refused" : "allowed"}]
    lappend named [list $v $id $hit [string trim $l]]
  }
  return [list $nsum $nrows $bad $named]
}

# ---- a450 Task 9b: the split-on card's report_cdc allowed list --------------------------
# jccard_a450_rules <bd> <tc>: the card's own rows under JC_A_CLK_SPLIT beyond a450_cdc_rules
# (hw/jc/a450/a450_cdc.tcl), as {label src_re dst_re}, ANCHORED regexps on the report's pin
# names.  One today: the CDC-11 reset fan-out (docs/debugging/2026-11-15_a450-card-split-
# timing.md, The 49 CDC rows): core_reset's peripheral_aresetn flop (or its replica) into
# mv4i_tcore's ar1 synchroniser.  The diagnosis's other two fan-out destinations,
# dfetch/g_dc.rst_s1 and gu.gdc.rst_s, do not exist under the split (the descriptor fetch is
# single-clock and the utilisation counters are not built: rtl/matvec_int4_desc_axi.vhd
# D_DUAL / U_ON), so no rule names them and a row into either is refused (a regression).
proc jccard_a450_rules {bd tc} {
  set b [a450_re_quote $bd]
  set t [a450_re_quote $tc]
  return [list [list core_reset_fanout_ar1 \
    "^$b/core_reset/U0/ACTIVE_LOW_PR_OUT_DFF\\\[0\\\]\\.FDRE_PER_N(_replica(_\\d+)?)?/C\$" \
    "^$t/ar1_reg/D\$"]]
}

# jccard_a450_cdc_split <rows> <rules> [refuse_ids]: the Critical rows jccard_cdc_scan found
# at no named synchroniser (its `bad` list, whole report lines), read against the split-on
# allowed list.  A row whose rule id is in refuse_ids (CDC-10: combinational logic before a
# synchroniser) is refused BEFORE any rule is tried, so no rule can allow one.  Returns
# {hits refused unknown}: a dict label -> count, and the refused and unmatched lines.
proc jccard_a450_cdc_split {rows rules {refuse_ids {CDC-10}}} {
  set hits [dict create]; set refused {}; set unknown {}
  foreach l $rows {
    set f [regexp -all -inline {\S+(?: \S+)*} [string trim $l]]
    set id [lindex $f 1]
    if {[lsearch -exact $refuse_ids $id] >= 0} { lappend refused $l; continue }
    set src [lindex $f end-1]; set dst [lindex $f end]
    set hit ""
    foreach rule $rules {
      lassign $rule lab sp dp
      if {[regexp -- $sp $src] && [regexp -- $dp $dst]} { set hit $lab; break }
    }
    if {$hit eq ""} { lappend unknown $l } else { dict incr hits $hit }
  }
  return [list $hits $refused $unknown]
}
