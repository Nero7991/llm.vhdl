# sim/elab_check.tcl -- TRACK ELABCLASS, 2026-09-20.
#
# THE 49-SECOND DISCRIMINATOR, MADE RUNNABLE.
#
# WHY THIS FILE EXISTS.  TRACK HDRCOST ran the first Vivado ever aimed at the
# `SCORE_HDR_TREE` generic and it died in 49 seconds:
#
#   Parameter HDR_TREE bound to: 1 - type: integer
#   ERROR: [Synth 8-11324] array index 8 out of range [rtl/attn_score_q12.vhd:488]
#
# The lever had passed a 20-point bit-exact grid against two C oracles, a
# 23-row mutation suite with attribution controls, and five green gate groups
# WHILE BEING UNSYNTHESISABLE.  The mechanism is general and it is not about
# that lever: an index that a run-time guard makes unreachable is NEVER
# EVALUATED by GHDL and is ALWAYS EVALUATED by Vivado, which unrolls the loop
# and folds every index statically.  **No bench in this repository can see that
# class of defect, and nothing scheduled the check that can.**
#
# CLAUDE.md already records the same shape one level up, about block-design
# ports: "Neither error is reachable by any bench, so no amount of simulation
# finds them [...] `--bd-only` costs 3 minutes and finds everything that is not
# a timing or placement result; nothing schedules it, which is why the build
# had been dead since 3a145fd with nobody aware."  This is that argument
# applied to plain RTL generics.
#
# WHAT IT DOES.  One `synth_design -rtl` (ELABORATION ONLY -- no mapping, no
# optimisation, no placement) of ONE entity at ONE generic binding, and prints
# a LINE-ANCHORED verdict.  It answers exactly one question -- "does this
# configuration elaborate" -- and deliberately answers nothing about area or
# timing, because that is what makes it cheap enough to schedule.
#
# `-rtl` IS NOT ASSUMED TO HAVE TEETH; IT IS TESTED.  The driver's first arm
# is `teeth`, which elaborates the PRE-FIX `attn_score_q12.vhd` at the card's
# geometry and MUST report `[Synth 8-11324]`.  A discriminator that has never
# been shown to fail has not been shown to work, and a cheaper mode that
# silently stops checking indices would be worse than no check at all.
#
# NO HARDWARE.  `synth_design -rtl` and `report_*` only; no bitstream, no
# programming, no hw_server.
#
# USAGE:
#   EC_TAG=<tag> EC_TOP=<entity> EC_RTL=<dir> EC_OUT=<dir> \
#   EC_GEN="A=1 B=true C=\"str\"" [EC_MODE=rtl|full] [EC_EXTRA=<dir>] \
#     vivado -mode batch -nojournal -source sim/elab_check.tcl
#
# EC_EXTRA, if set, is read AFTER EC_RTL and overrides same-named entities --
# it is how a mutant or a candidate fix is elaborated without disturbing the
# clean tree.
#
# Prints, as its LAST action, one of:
#   ELABCHK_PASS <tag>
#   ELABCHK_FAIL <tag>
# The caller gates on the ANCHORED form `^ELABCHK_PASS <tag>$`, because this
# log contains this script's own source text and an unanchored grep matches the
# line that writes the line.  That trap has fired twice in this project.

set part [expr {[info exists ::env(EC_PART)] ? $::env(EC_PART) : "xcvu33p-fsvh2104-2L-e"}]

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set tag    [envor EC_TAG   unnamed]
set top    [envor EC_TOP   ""]
set rtldir [envor EC_RTL   rtl]
set outdir [envor EC_OUT   .]
set gens   [envor EC_GEN   ""]
set mode   [envor EC_MODE  rtl]
set extra  [envor EC_EXTRA ""]

if {$top eq ""} { puts "ELABCHK_ABORT $tag: EC_TOP not set"; exit 9 }
file mkdir $outdir

set t0 [clock seconds]
puts "ELABCHK_BEGIN tag=$tag top=$top part=$part mode=$mode"
puts "ELABCHK_GENERICS tag=$tag gen=\"$gens\""
puts "ELABCHK_EXTRA tag=$tag extra=\"$extra\""

create_project -in_memory -part $part

# Read the whole rtl directory EXCEPT the other tracks' OOC harness tops.
# MEASURED by TRACK LEVERCOST: `rtl/ooc_gdnadapt_top.vhd` does not compile at
# HEAD (it uses B_CONST_HBM and never declares it), `read_vhdl` accepts it
# silently, and synth_design then dies on a file the target cannot reach.
set nread 0; set nskip 0; set nexcl 0
foreach f [lsort [glob -nocomplain -directory $rtldir *.vhd]] {
    if {[string match "ooc_*_top.vhd" [file tail $f]]} { incr nexcl; continue }
    if {[catch {read_vhdl -vhdl2008 $f} e]} {
        puts "ELABCHK_READ_SKIP $f : $e"; incr nskip
    } else { incr nread }
}
# EC_EXTRA last, so it wins on a duplicate entity.
set nex 0
if {$extra ne ""} {
    foreach f [lsort [glob -nocomplain -directory $extra *.vhd]] {
        if {[catch {read_vhdl -vhdl2008 $f} e]} {
            puts "ELABCHK_READ_SKIP $f : $e"
        } else { incr nex; puts "ELABCHK_OVERRIDE tag=$tag [file tail $f]" }
    }
}
puts "ELABCHK_READ tag=$tag files=$nread skipped=$nskip excluded=$nexcl override=$nex"

# EC_GEN is parsed as a TCL LIST, not re-evaluated, and the command below is
# built with {*} rather than `eval`.  A string generic's value must survive
# with its VHDL quotes attached -- Vivado wants `-generic {NAME="text"}` -- and
# `eval` on a concatenated command line strips exactly those quotes.  So the
# caller writes the value in braces, e.g.
#     EC_GEN='NORM_REAL=true NORM_W_IMAGE={"/path/norm_w_9b.hex"}'
# and Tcl's list parser hands the inner quotes through untouched.
set gl {}
foreach g $gens { lappend gl -generic $g }

# THE DISCRIMINATOR ITSELF.
#
# `-rtl` stops after RTL elaboration.  That is the phase that unrolls loops and
# folds constant index expressions, which is the phase HDRCOST's defect dies
# in; it is NOT the phase that maps, optimises, places or routes, which is why
# it costs seconds rather than the ~1,000 s a full OOC synthesis of the same
# entity costs.  `-rtl_skip_ip` keeps it from elaborating IP it does not need.
#
# `EC_MODE=full` runs the ordinary synth_design instead, for the case where a
# candidate must be confirmed against the real flow.  The two modes are NOT
# interchangeable as evidence about anything except elaboration.
set ok 1
set t1 [clock seconds]
if {$mode eq "full"} {
    if {[catch {synth_design -mode out_of_context -top $top -part $part \
                    -flatten_hierarchy none {*}$gl} err]} { set ok 0 }
} else {
    if {[catch {synth_design -rtl -rtl_skip_ip -mode out_of_context \
                    -top $top -part $part {*}$gl} err]} { set ok 0 }
}
set tel [expr {[clock seconds] - $t1}]
puts "ELABCHK_SECONDS tag=$tag elaborate=$tel total=[expr {[clock seconds]-$t0}]"

if {!$ok} {
    # THIS TEXT IS NOT THE ERROR, AND KNOWING THAT SAVES A READER FIFTEEN
    # MINUTES.  `catch` around synth_design returns only
    #   ERROR: [Vivado_Tcl 4-5] Elaboration failed - please see the console
    # whatever went wrong.  The cause is in the Vivado log, and the DRIVER
    # greps `^ERROR` out of it into its own stdout.  Read the driver's
    # batch.log, not elabfail_<tag>.txt.
    # Write the raw text out verbatim anyway; a summary of an error is not the
    # error, and an empty file would be worse than an unhelpful one.
    set fh [open [file join $outdir elabfail_$tag.txt] w]
    puts $fh $err
    close $fh
    puts "ELABCHK_ERRTEXT_BEGIN $tag"
    foreach l [split $err "\n"] { puts "  | $l" }
    puts "ELABCHK_ERRTEXT_END $tag"
    puts "ELABCHK_FAIL $tag"
    exit 1
}

# A PASS is only a pass if something was actually built.  A synth_design that
# elaborates an empty design would otherwise report success over nothing -- the
# same shape as this project's recorded checker that printed PASS over an
# object neither of its checks ever read.
set ncell [llength [get_cells -hier -quiet]]
set nport [llength [get_ports -quiet]]
puts "ELABCHK_SIZE tag=$tag rtl_cells=$ncell ports=$nport"
if {$nport == 0} {
    puts "ELABCHK_FAIL $tag"
    exit 1
}
puts "ELABCHK_PASS $tag"
