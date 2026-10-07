# hw/jc/card/jccard_levers.tcl -- pure string parsing of Vivado's synthesis trace
# `Parameter <NAME> bound to: <value>` lines. No Vivado command, no package beyond
# the base Tcl interpreter, so Task 9's test can run it under plain `tclsh` against
# real log excerpts, with no project, no license and no Vivado process.
#
# Task 9 fix round 1, C1. CRITICAL, MEASURED on three real builds (bd_wrapper.vds
# inside each build's synth_1 run directory; EVIDENCE is the excerpt fixtures this
# proc's test reads verbatim):
#   build20     (levers off): Parameter NWIDE       bound to: 0 - type: bool
#               Parameter SWEEP_PIPE  bound to: 0 - type: bool
#               Parameter SCORE_EARLY bound to: 0 - type: bool
#   build21     (C's levers on, NWIDE untouched): Parameter NWIDE bound to: 0
#               Parameter SWEEP_PIPE bound to: 1 ; Parameter SCORE_EARLY bound to: 1
#   build27b_1  (every lever on): NWIDE/SWEEP_PIPE/SCORE_EARLY/FAST_POP all `1`.
# Vivado spells a `boolean` generic's bound value as the NUMBER 0/1, never the word
# "false"/"true" -- the original build_card.tcl compared against the word and so
# refused build20 itself, the one build its own levers patch is supposed to match.
# "false"/"true" are still accepted (a future lever might not be type bool; a
# string-typed parameter such as CB_STYLE is never 0/1), but a bare word that is
# neither is reported, never silently coerced.
#
# ALSO C1: the line does not live in Vivado's own `runme.log` for a project-mode
# synth_1 run. runme.log is the project launcher's own log; the synthesis ENGINE's
# full elaboration trace -- every module's own `Parameter ... bound to` line, which
# is what carries NWIDE/SWEEP_PIPE/SCORE_EARLY (deep inside fk33_llama_top, never at
# a module-reference boundary) -- is logged only to `<top>.vds` in the same run
# directory (MEASURED: runme.log had 782 unrelated `bound to` lines, zero for NWIDE,
# in build20; bd_wrapper.vds had exactly one). build_card.tcl now reads `<top>.vds`
# where `<top>` is `[get_property top [current_fileset]]` (`jc_card_top` for this
# design), never `runme.log`, for exactly this check.

# True (1), false (0), or -1 if the token is neither -- a token is never guessed.
proc jccard_lever_bool {tok} {
  switch -- [string tolower $tok] {
    0 - false { return 0 }
    1 - true  { return 1 }
    default   { return -1 }
  }
}

# Every `Parameter $name bound to: <value>` token found in $text, in the order
# found. $name is a literal generic name (NWIDE, SWEEP_PIPE, ...), never a pattern.
proc jccard_lever_tokens {name text} {
  set out {}
  foreach {whole v} [regexp -all -inline -- "Parameter $name bound to: (\\S+)" $text] {
    lappend out $v
  }
  return $out
}

# {status detail}. status is one of:
#   off      every occurrence parses as boolean false (0 or "false"), >=1 found
#   on       every occurrence parses as boolean true (1 or "true"), >=1 found
#   missing  no occurrence at all -- an absence proves nothing (hw/fk33/CLAUDE.md:
#            "a lever's absence from the log proves nothing"), so this is refused
#            by the caller exactly like a wrong value, never read as a silent pass
#   mixed    more than one distinct boolean value, or a token that parses as
#            neither 0/false nor 1/true (a stray format change, refused rather than
#            guessed at)
proc jccard_lever_status {name text} {
  set toks [jccard_lever_tokens $name $text]
  if {[llength $toks] == 0} { return [list missing "no bind line found"] }
  set bools {}
  foreach t $toks {
    set b [jccard_lever_bool $t]
    if {$b < 0} { return [list mixed "unrecognised value '$t' among {$toks}"] }
    lappend bools $b
  }
  set uniq [lsort -unique $bools]
  if {[llength $uniq] != 1} {
    return [list mixed "inconsistent values {$toks} ([llength $toks] occurrence(s))"]
  }
  if {[lindex $uniq 0] == 0} {
    return [list off "[llength $toks] occurrence(s), all bound to 0/false"]
  }
  return [list on "[llength $toks] occurrence(s), all bound to 1/true"]
}

# CLI, for the test only: `tclsh jccard_levers.tcl <name> <file>` prints
# "STATUS <status>" and "DETAIL <detail>". Guarded so sourcing this file from
# build_card.tcl (inside Vivado, where argv0 is vivado's own) never runs it.
if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
  if {[llength $argv] != 2} {
    puts "usage: tclsh jccard_levers.tcl <parameter-name> <log-excerpt-file>"
    exit 2
  }
  set text [read [open [lindex $argv 1]]]
  set res [jccard_lever_status [lindex $argv 0] $text]
  puts "STATUS [lindex $res 0]"
  puts "DETAIL [lindex $res 1]"
}
