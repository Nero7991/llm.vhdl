# Select a JTAG-AXI master by what it ANSWERS, never by its name or its index.
#
# WHY THIS FILE EXISTS.  Ten scripts in this directory did
# `get_hw_axis hw_axi_1`.  That was correct on the two-master bitstreams and is
# WRONG on the engine bitstream, and the failure is SILENT: an unmapped read
# returns a decode sentinel rather than erroring, so a script reads a plausible
# number from the wrong slave and reports it as a measurement.
#
# MEASURED, and this is the whole argument.  The same three masters enumerate
# DIFFERENTLY on two builds of the same source tree:
#
#   tcl/telemetry.tcl:10 (first-light, TWO masters)
#       hw_axi_1 = jtag_axil     hw_axi_2 = jtag_hbm
#
#   tcl/aux_probe.log:178 (thermal build, 2026-08-28, THREE masters)
#       hw_axi_1  0x00000000 -> 0x41555831   "AUX1"     = jtag_aux
#       hw_axi_2  0x00000000 -> 0xDEC0DEE3   DECERR     = jtag_axil
#       hw_axi_3  0x00000000 -> 0x4D563449   HBM bytes  = jtag_hbm
#
#   tcl/pcieep_jtag.log (engine build, 2026-08-29, THREE masters)
#       hw_axi_2  0x0000A000 -> 0x464B3333   "FK33"     = jtag_axil
#
# So hw_axi_1 was jtag_axil on one build and jtag_aux on the next.  Enumeration
# order is an implementation result, not a contract, and nothing in a master's
# PROPERTIES distinguishes them -- `get_property ADDR_WIDTH`/`DATA_WIDTH` on a
# hw_axi object does not exist (MEASURED: tcl/pcieep_jtag.log prints
# "ADDR_WIDTH=? DATA_WIDTH=?" for all three).
#
# THE SIGNATURE, and why it is positive rather than an elimination.  Read
# address 0x00000000 on every master.  In every bitstream in this repository:
#
#   jtag_aux   -> 0x41555831   aux_id sits at offset 0 of jtag_aux's own space
#                              (gen_pcieep.py AUX_ADDR; rtl/fk33_aux.vhd:209)
#   jtag_axil  -> 0xDEC0DEE3   the AXI-Lite BAR's lowest assigned segment is
#                              SYSMON at 0x3000, so 0 is unmapped and the
#                              smartconnect answers with its DECERR magic
#   jtag_hbm   -> HBM bytes    HBM_MEM00 is assigned at offset 0
#
# Two of the three are POSITIVE identifications against a constant the fabric
# holds.  The memory master is then the remaining one -- an elimination, but an
# elimination founded on two positives rather than on an ordinal, and it
# REFUSES unless exactly one master is left over.
#
# THE MEMORY MASTER IS 64 BITS WIDE AND THAT CHANGES HOW IT MUST BE READ.
# build_fk33_pcieep.tcl:251 sets jtag_hbm to M_AXI_DATA_WIDTH 64; jtag_axil and
# jtag_aux are 32.  `lindex [report_hw_axi_txn -t d4 $t] 1` picks ONE 32-bit
# group out of the beat, so on a 64-bit master it returns half the word and
# WHICH half is not established here.  fk33_axi_rd32 is therefore documented as
# valid for 32-bit masters only; use fk33_axi_report on the memory master and
# read the whole beat.
#
# TWO DEFECTS IN THE OLD READ HELPERS, both of which produced ghost readings and
# both of which are avoided below.
#
#  1. `get_hw_axi_txns t` with no -of_objects names EVERY master's transaction
#     called `t`, so run_hw_axi could re-run a different master's transaction.
#  2. `create_hw_axi_txn -quiet` returns quietly on failure, leaving the
#     PREVIOUS transaction of that name in place; the following `run_hw_axi`
#     then re-runs it and its stale data is reported as this master's answer.
#     That is the most probable origin of 0xA4960CF2 appearing from two
#     different masters at two different addresses in tcl/pcieep_jtag.log --
#     see docs/debugging/2026-08-29_addrmap-engine-build.md.
#
#     So: no -quiet on create or run, catch instead, and always -of_objects.

proc fk33_axi_txn_name {ax} {
    return "fk33sel_[string map {: _ / _ - _} [get_property NAME $ax]]"
}

# One 32-bit read.  Returns an 8-character uppercase hex string, or the literal
# "-1" for NO ANSWER (transaction could not be created or did not complete).
# -1 is the no-answer token this directory already uses (tcl/aux_probe.tcl:200).
proc fk33_axi_rd32 {ax addr} {
    set nm [fk33_axi_txn_name $ax]
    catch {delete_hw_axi_txn [get_hw_axi_txns -quiet -of_objects $ax $nm]}
    if {[catch {create_hw_axi_txn $nm $ax -address $addr -type read -len 1}]} {
        return "-1"
    }
    set tx [get_hw_axi_txns -quiet -of_objects $ax $nm]
    if {[llength $tx] != 1} { return "-1" }
    if {[catch {run_hw_axi $tx}]} { return "-1" }
    if {[catch {set rep [report_hw_axi_txn -t d4 $tx]}]} { return "-1" }
    set v [lindex $rep 1]
    if {![string is integer -strict $v]} { return "-1" }
    return [format "%08X" [expr {$v & 0xFFFFFFFF}]]
}

# The RAW report string for one read, unparsed.  This is the honest instrument
# on a master whose data width is not 32: it shows every group and their order,
# which `lindex ... 1` throws away.
proc fk33_axi_report {ax addr {len 1}} {
    set nm [fk33_axi_txn_name $ax]
    catch {delete_hw_axi_txn [get_hw_axi_txns -quiet -of_objects $ax $nm]}
    if {[catch {create_hw_axi_txn $nm $ax -address $addr -type read -len $len} e]} {
        return "CREATE_FAILED: $e"
    }
    set tx [get_hw_axi_txns -quiet -of_objects $ax $nm]
    if {[llength $tx] != 1} { return "TXN_NOT_FOUND" }
    if {[catch {run_hw_axi $tx} e]} { return "RUN_FAILED: $e" }
    if {[catch {set rep [report_hw_axi_txn -t x4 $tx]} e]} { return "REPORT_FAILED: $e" }
    return $rep
}

set FK33_AUX_MAGIC   41555831
set FK33_DECERR      DEC0DEE3

# Classify every master.  Returns a list of {name kind answer} triples with kind
# in {aux axil mem dead}, and PRINTS the evidence, because a selection nobody
# can see in the log is not auditable.
proc fk33_axi_classify {} {
    global FK33_AUX_MAGIC FK33_DECERR
    set out {}
    set axis [get_hw_axis -quiet]
    puts "FK33_AXI_SELECT probing [llength $axis] master(s) at 0x00000000"
    foreach a $axis {
        set v [fk33_axi_rd32 $a 00000000]
        if {$v eq "-1"} {
            set kind dead
        } elseif {$v eq $FK33_AUX_MAGIC} {
            set kind aux
        } elseif {$v eq $FK33_DECERR} {
            set kind axil
        } else {
            set kind mem
        }
        puts [format "  %-10s 0x00000000 -> 0x%-8s  %s" \
              [get_property NAME $a] $v $kind]
        lappend out [list $a $kind $v]
    }
    return $out
}

proc fk33_axi_of_kind {cls kind} {
    set r {}
    foreach e $cls { if {[lindex $e 1] eq $kind} { lappend r [lindex $e 0] } }
    return $r
}

# Pick exactly one master of a kind, or REFUSE.  Refusing is the point: every
# caller of this file either writes a power rail, bit-bangs the board I2C bus,
# or reports a number somebody will act on.
proc fk33_axi_pick {kind {cls ""}} {
    if {$cls eq ""} { set cls [fk33_axi_classify] }
    set hit [fk33_axi_of_kind $cls $kind]
    if {[llength $hit] == 1} {
        set a [lindex $hit 0]
        puts "FK33_AXI_SELECT $kind = [get_property NAME $a]"
        return $a
    }
    set msg "FK33_AXI_SELECT REFUSING TO GUESS: [llength $hit] master(s) classify as '$kind', expected exactly 1.\n"
    foreach e $cls {
        append msg [format "         %-10s -> 0x%-8s  %s\n" \
                    [get_property NAME [lindex $e 0]] [lindex $e 2] [lindex $e 1]]
    }
    append msg "       'aux' answers 0x41555831 at 0, 'axil' answers the DECERR magic\n"
    append msg "       0xDEC0DEE3 at 0, 'mem' answers anything else, 'dead' does not\n"
    append msg "       answer at all.  If everything is 'dead' the card is not\n"
    append msg "       configured, or the PCIe link is down so xdma/axi_aclk (which\n"
    append msg "       clocks jtag_axil and jtag_hbm) is not running -- check LED 6.\n"
    error $msg
}

# Corroborate the AXI-Lite pick against a build-specific identity register
# before letting a caller act on it.  addr/want are hex strings without 0x.
# Returns 1 on agreement, 0 otherwise, and always prints what it saw.
proc fk33_axi_confirm {ax addr want} {
    set v [fk33_axi_rd32 $ax $addr]
    set ok [expr {[string equal -nocase $v $want]}]
    puts [format "FK33_AXI_SELECT confirm %s at 0x%s -> 0x%s (want 0x%s) %s" \
          [get_property NAME $ax] $addr $v $want [expr {$ok ? "OK" : "MISMATCH"}]]
    return $ok
}

# ---------------------------------------------------------------------------
# SELF TEST.  AXISEL_SELFTEST=1 under a plain tclsh, no hardware, no Vivado.
#
# It exists because the whole value of this file is that it REFUSES in the cases
# where the old code guessed, and a refusal path that has never been made to
# fire is not a refusal path.  Every case below is a real configuration seen in
# this repository's logs or a real failure mode of the card.
if {[info exists ::env(AXISEL_SELFTEST)]} {
    # --- Vivado stubs.  ::AXISEL_FAKE maps master name -> answer at 0x0, where
    # the answer is an 8-char hex string or "-1" for "the transaction failed".
    proc get_hw_axis {args} {
        set r {}
        foreach {n v} $::AXISEL_FAKE { lappend r $n }
        return $r
    }
    proc get_property {p obj} { return $obj }
    proc delete_hw_axi_txn {args} {}
    proc get_hw_axi_txns {args} { return [list [lindex $args end]] }
    proc create_hw_axi_txn {nm ax args} {
        set ::AXISEL_CUR $ax
        set i [lsearch -exact $args -address]
        set ::AXISEL_ADDR [lindex $args [expr {$i + 1}]]
        return $nm
    }
    proc run_hw_axi {tx} {
        set v [dict get $::AXISEL_FAKE $::AXISEL_CUR]
        if {$v eq "-1"} { error "transaction did not complete" }
    }
    proc report_hw_axi_txn {args} {
        set v [dict get $::AXISEL_FAKE $::AXISEL_CUR]
        # token 0 is the address column, token 1 the first data group -- the
        # shape the real report has for a 32-bit master.
        return [list $::AXISEL_ADDR [expr {"0x$v" + 0}]]
    }

    set fails 0
    proc expect_pick {label fake kind want} {
        set ::AXISEL_FAKE $fake
        if {[catch {set got [get_property NAME [fk33_axi_pick $kind]]} e]} {
            puts "  FAIL $label: refused, expected '$want'"
            incr ::fails; return
        }
        if {$got ne $want} { puts "  FAIL $label: picked $got, expected $want"; incr ::fails }
    }
    proc expect_refuse {label fake kind} {
        set ::AXISEL_FAKE $fake
        if {![catch {fk33_axi_pick $kind} e]} {
            puts "  FAIL $label: picked one, expected a REFUSAL"
            incr ::fails; return
        }
    }

    # The engine build, MEASURED (tcl/aux_probe.log:178 + tcl/pcieep_jtag.log).
    set eng {hw_axi_1 41555831 hw_axi_2 DEC0DEE3 hw_axi_3 4D563449}
    expect_pick   "engine/aux"   $eng aux  hw_axi_1
    expect_pick   "engine/axil"  $eng axil hw_axi_2
    expect_pick   "engine/mem"   $eng mem  hw_axi_3
    # The two-master first-light build: no aux domain at all.
    set fl {hw_axi_1 DEC0DEE3 hw_axi_2 00000000}
    expect_pick   "firstlight/axil" $fl axil hw_axi_1
    expect_refuse "firstlight/aux"  $fl aux
    # THE CASE THE OLD CODE GOT WRONG: the same two roles, opposite ordinals.
    set flip {hw_axi_1 4D563449 hw_axi_2 DEC0DEE3}
    expect_pick   "flipped/axil"  $flip axil hw_axi_2
    # Link down: xdma/axi_aclk stopped, so jtag_axil and jtag_hbm are in reset
    # and only the free-running aux master answers.
    set down {hw_axi_1 41555831 hw_axi_2 -1 hw_axi_3 -1}
    expect_pick   "linkdown/aux"  $down aux hw_axi_1
    expect_refuse "linkdown/axil" $down axil
    expect_refuse "linkdown/mem"  $down mem
    # Card not configured at all.
    expect_refuse "dead/axil" {hw_axi_1 -1 hw_axi_2 -1} axil
    expect_refuse "dead/none" {} axil
    # Two masters that both look like memory: elimination is not enough and the
    # old two-candidate fallback in pcieep_jtag.tcl is exactly this case.
    expect_refuse "twomem/mem" {hw_axi_1 DEC0DEE3 hw_axi_2 11111111 hw_axi_3 22222222} mem
    # ADDED after a mutation that did NOT bite.  Collapsing 'dead' into 'mem'
    # passed every case above, because in the link-down vector BOTH silent
    # masters then classify as mem and the pick still refuses -- for the wrong
    # reason.  This vector separates them: one live memory master alongside one
    # silent master must still pick the live one, and does not if a no-answer is
    # treated as an answer.
    expect_pick "onedead/mem" {hw_axi_1 DEC0DEE3 hw_axi_2 -1 hw_axi_3 4D563449} mem hw_axi_3

    if {$fails} { puts "AXISEL_SELFTEST FAIL $fails"; exit 1 }
    puts "AXISEL_SELFTEST OK 12 cases"
    exit 0
}
