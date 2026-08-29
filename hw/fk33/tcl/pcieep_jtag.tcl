# JTAG-side check of the PCIe endpoint bitstream.
#
# What this isolates, and in which direction the evidence runs:
#
# In this bitstream the ENTIRE AXI fabric -- including both JTAG-AXI masters --
# is clocked by xdma/axi_aclk and reset by xdma/axi_aresetn, both of which are
# derived from the PCIe reference clock and released only once the link is up.
# So:
#
#   every read below SUCCEEDS  ->  conclusive.  Reference clock present, PCIe
#                                  user clock running, link up, AXI-Lite path
#                                  and DMA-side HBM path both alive.  If the
#                                  host still cannot see the card, the fault is
#                                  in enumeration or the driver, not the card.
#
#   reads hang or return junk  ->  AMBIGUOUS, and deliberately so.  It could be
#                                  no reference clock, an untrained link, or a
#                                  bitstream that did not configure.  Separate
#                                  them with LED 6 (link status, no instrument)
#                                  and with the ROOT PORT's LnkSta on the host,
#                                  which reports link state even when nothing
#                                  enumerates.  See host/fk33_pcie_check.sh.
#
# Nothing here writes to the board's I2C bus, and the HBM write is confined to
# a 4 KB scratch page at the very top of the address map.

source [file join [file dirname [info script]] target_select.tcl]
source [file join [file dirname [info script]] axi_select.tcl]

puts "PCIEEP_CHECK begin"

open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
# -update_hw_probes false so refresh does not hunt for debug cores.
refresh_hw_device -quiet -update_hw_probes false $d
# NOT `get_property REGISTER.IDCODE`.  That property does not exist on this
# hw_device and ABORTS the whole script, which is how the 2026-08-29 endpoint
# check died at its first line after a successful configure, reporting nothing
# about a link that was in fact up.  The trap was already written down in
# tcl/flash_common.tcl:56, tcl/aux_probe.tcl:172 and tcl/flash_status.tcl:65
# and had been removed from all three -- leaving it live in the one file whose
# job is to check the endpoint.  A trap documented three times and fixed
# nowhere it mattered.
puts "PART   [get_property PART [current_hw_device]]"

set axis [get_hw_axis]
puts "AXI_MASTERS $axis"
if {[llength $axis] < 2} {
    puts "PCIEEP_FAIL: expected at least 2 JTAG-AXI masters, found [llength $axis]."
    puts "             The device is not running the endpoint bitstream."
    puts "PCIEEP_DONE"
    close_hw_target
    exit 0
}

# `report_hw_axi_txn -t d4` prints the data word in DECIMAL (that is what the
# `d` means), as a SIGNED 32-bit value.  rd returns it normalised to an unsigned
# integer, and rdhex formats it.  Everything downstream compares NUMBERS.
#
# THIS COST A FALSE ALARM ON 2026-08-29.  The identity check used to compare the
# decimal TEXT against the hex string "464B3333", which can never match: the
# endpoint reported PCIEEP_FAIL "this is not fk33_pcieep" on a card that was
# answering with exactly the right magic (decimal 1179333427 = 0x464B3333).
proc rd_words {ax addr} {
    # NO -quiet ON create_hw_axi_txn.  MEASURED by TRACK ADDRMAP: -quiet returns
    # QUIETLY ON FAILURE and leaves the PREVIOUS txn of that name in place, so
    # run_hw_axi then re-runs the OLD transaction and reports a stale value as
    # though it were fresh.  That is where 0xA4960CF2 came from: it was the
    # immediately preceding read, reported twice.  A `catch` around a `-quiet`
    # command catches nothing, so the earlier fix here removed one silencer and
    # left the other.
    #
    # `-t x4` prints HEX.  The old code used `-t d4`, which prints signed
    # DECIMAL, and compared that text against hex strings.
    #
    # Returns the LIST of 32-bit words.  A 64-bit master returns TWO per read
    # and `lindex ... 1` silently took one of them; which one was not known.
    # MEASURED at the DMA BRAM against a pattern the host had written:
    #   hw_axi_3 at 0x200000000 -> <464b3333 4a544147>
    # against a host write of 464B3333 4A544147 12345678 FEDCBA98, so the first
    # word is the LOW word and the order is little-endian as expected.
    create_hw_axi_txn -force t $ax -address $addr -type read
    run_hw_axi [get_hw_axi_txns t]
    set r [report_hw_axi_txn -t x4 [get_hw_axi_txns t]]
    return [lrange $r 1 end]
}
proc rd {ax addr} {
    set w [rd_words $ax $addr]
    if {![llength $w]} { error "no data returned from $addr" }
    return [expr 0x[lindex $w 0]]
}
proc rdhex {ax addr} { return [format %08X [rd $ax $addr]] }
proc wr {ax addr data} {
    # No -quiet, for the same reason as rd_words above.
    create_hw_axi_txn -force t $ax -address $addr -data $data -type write
    run_hw_axi [get_hw_axi_txns t]
}

# ---- PICK THE AXI-LITE MASTER BY WHAT IT ANSWERS, NOT BY ITS ORDINAL.
#
# This used to be `set axil [lindex $axis 1]`.  The block design happens to
# enumerate jtag_axil second, so with two masters it worked by coincidence; the
# engine build has THREE and the comment above it ("hw_axi_1 is jtag_hbm,
# hw_axi_2 is jtag_axil") was a statement about enumeration order, which is not
# a contract.  Same defect class as selecting a JTAG target by index, which
# already cost this project a factory flash image.
#
# There is nothing in a master's PROPERTIES to tell them apart -- all three
# report NAME hw_axi_N and PROTOCOL AXI4_Full.  But the identity register makes
# them SELF-IDENTIFYING: the AXI-Lite master is the one that answers 0x464B3333
# at 0xA000.  A master whose map does not cover it returns a decode sentinel
# (MEASURED: hw_axi_1 returns 0xDEC0DEE3 there).  So probe, and refuse if the
# answer is not unique.
set ID_MAGIC 0x464B3333
set cand {}
foreach a $axis {
    if {[catch {rd $a A000} v]} { continue }
    puts [format "  probe %s at 0xA000 -> 0x%08X" [get_property NAME $a] $v]
    if {$v == $ID_MAGIC} { lappend cand $a }
}
if {[llength $cand] != 1} {
    puts "PCIEEP_FAIL: [llength $cand] of [llength $axis] JTAG-AXI masters answered"
    puts "             the identity register 0x464B3333 at 0xA000; expected exactly 1."
    if {[llength $cand] == 0} {
        puts "             No master identifies as fk33_pcieep's AXI-Lite.  Either the"
        puts "             fabric is not running this bitstream, or the link is down"
        puts "             so axi_aclk is not running.  Check LED 6 and LnkSta."
    }
    puts "PCIEEP_DONE"
    close_hw_target
    exit 0
}
set axil [lindex $cand 0]
# The HBM master is the 64-bit one, and is whichever is NOT the AXI-Lite one.
# With more than two masters this is still ambiguous, so say so rather than
# guessing: an HBM result read from the wrong master is worse than no result.
set hbm ""
set hbmc {}
foreach a $axis { if {$a ne $axil} { lappend hbmc $a } }
if {[llength $hbmc] == 1} {
    set hbm [lindex $hbmc 0]
} else {
    # More than one candidate, so elimination is not enough.  Identify by what
    # answers, as with the AXI-Lite master above: the memory master is the one
    # whose map covers the DMA BRAM.  That window is chosen deliberately -- it
    # has NO memory controller behind it, so this identification cannot be
    # confused by HBM initialisation not having completed, which is precisely
    # the ambiguity the HBM check further down exists to report.
    #
    # This is a round trip and therefore NOT an oracle for the memory itself.
    # It is only being used to tell two masters apart, and the real four-word
    # check still runs afterwards.
    # 64 BITS OF DATA.  MEASURED: a 32-bit -data on the 64-bit master is
    # refused outright -- "Data value '5A5A0F0F' does not fill up complete
    # 64-bit data words.  Last data word has only 8 bits."  The master's width
    # dictates the transaction shape, and the 32-bit masters cannot even issue
    # the 34-bit address ("Address Value '200000000' is too large").  Between
    # them those two errors identify all three masters without guessing.
    set probe_a 200000000
    set probe_v 5A5A0F0F0F5A5A5A
    foreach a $hbmc {
        # Do NOT swallow the error.  A `catch ... continue` here hid the fact
        # that both candidates ERRORED rather than returning wrong data, which
        # is a completely different diagnosis, and left the run reporting
        # "0 answered" with no way to tell why.
        if {[catch {
            wr $a $probe_a $probe_v
            set gw [rd_words $a $probe_a]
            # rd_words returns low word first (MEASURED against a pattern the
            # host had written), so reassemble high:low to compare with -data.
            set got [expr {[llength $gw] >= 2
                           ? "[lindex $gw 1][lindex $gw 0]"
                           : [lindex $gw 0]}]
            set got [string toupper $got]
        } perr]} {
            puts "  probe [get_property NAME $a] at 0x$probe_a ERRORED: $perr"
            continue
        }
        puts "  probe [get_property NAME $a] at 0x$probe_a -> 0x$got"
        if {$got eq $probe_v} { lappend hbmhit $a }
    }
    if {[info exists hbmhit] && [llength $hbmhit] == 1} {
        set hbm [lindex $hbmhit 0]
    } else {
        puts "PCIEEP_NOTE: could not identify the memory master: [llength $hbmc] candidates,"
        puts "             [expr {[info exists hbmhit] ? [llength $hbmhit] : 0}] answered the DMA BRAM probe."
        puts "             HBM and DMA BRAM checks are SKIPPED rather than run against"
        puts "             a guess.  A result read from the wrong master is worse than"
        puts "             no result."
    }
}
puts "AXI_LITE_MASTER [get_property NAME $axil]"
if {$hbm ne ""} { puts "AXI_HBM_MASTER  [get_property NAME $hbm]" }

# ---- 1. AXI-Lite.  The cheapest possible proof that the PCIe user clock runs.
# SYSMON is read-only and has a known-good cross-check: the same numbers came
# out of tcl/telemetry.tcl over the probe bitstream, so a plausible reading here
# is not just "a register responded", it is "the same silicon says the same
# thing through a different clock domain".
if {[catch {
    set traw [rd $axil 3400]
    set vraw [rd $axil 3404]
} err]} {
    puts "PCIEEP_FAIL: AXI-Lite read errored: $err"
    puts "             xdma/axi_aclk is not running or axi_aresetn is held."
    puts "             Link is almost certainly down.  Check LED 6 and the"
    puts "             host root port's LnkSta before touching the bitstream."
    puts "PCIEEP_DONE"
    close_hw_target
    exit 0
}
# ---- 1a. Identity register, read over JTAG.  This is the same 0x464B3333 the
# host reads through the BAR, and reading it BOTH ways is what separates
# "the fabric holds the wrong bitstream" from "the host path is broken".
#   JTAG OK + host OK   -> everything works
#   JTAG OK + host bad  -> the fabric is right; the fault is link, BAR or driver
#   JTAG bad            -> the FPGA is not running fk33_pcieep at all, and no
#                          amount of host-side debugging will change that
# Compared NUMERICALLY.  See the note on rd above: -t d4 is decimal.
set idm [rd    $axil A000]
set idb [rdhex $axil A008]
if {$idm == $ID_MAGIC} {
    puts [format "ID_OK magic=0x%08X build=0x%s  (\"FK33\")" $idm $idb]
} else {
    puts [format "PCIEEP_FAIL: id magic reads 0x%08X, expected 0x%08X." $idm $ID_MAGIC]
    puts "             The AXI-Lite path answers but this is not fk33_pcieep."
    puts "             Reconfigure before debugging anything on the host side."
}

set temp [expr {$traw * 507.6 / 65536.0 - 279.43}]
set vcc  [expr {$vraw * 3.0 / 65536.0}]
puts [format "SYSMON die=%.1f C  VCCINT=%.4f V  (raw 0x%x 0x%x)" $temp $vcc $traw $vraw]

# The VCCINT reading is the second half of the bring-up order check: if it says
# ~0.678 V the pot was never stepped, or the board was power-cycled after it
# was, and this die is running below its characterised floor.
if {$vcc < 0.698} {
    puts [format "PCIEEP_WARN: VCCINT %.4f V is BELOW the 0.698 V -2L floor." $vcc]
    puts "             Re-run ./pcieep.sh without --no-vccint, or raise it from"
    puts "             the host with host/fk33ctl.py vccint."
} elseif {$vcc > 0.760} {
    puts [format "PCIEEP_WARN: VCCINT %.4f V is above the 0.760 V ceiling used" $vcc]
    puts "             by tcl/vccint_step.tcl.  Investigate before loading anything."
} else {
    puts [format "VCCINT_OK %.4f V" $vcc]
}
if {$temp < 5.0 || $temp > 95.0} {
    puts [format "PCIEEP_WARN: die temperature %.1f C is implausible; SYSMON may" $temp]
    puts "             be returning a stale or unclocked value."
}

# ---- 2. GPIO.  Proves the AXI-Lite path reaches a WRITABLE peripheral, which
# SYSMON cannot show.  Read-only: TRI resets to all-ones (everything released)
# and this reads it back without touching either the data or the tri register,
# so the board's I2C bus is never driven.
set tri [rd $axil 9004]
set dat [rd $axil 9000]
puts [format "GPIO tri=0x%08x data=0x%08x  (tri must be 0x3 or wider all-ones at reset)" $tri $dat]

# ---- 3. HBM through the JTAG master.  Isolates the memory path from the DMA
# path: if this works and host DMA does not, the fault is in XDMA or the driver,
# not in HBM or the smartconnect.  Scratch page is the last 4 KB of the 8 GB map.
# Two 64-bit words carrying the same four 32-bit values as before, high:low,
# because rd_words returns the low word first.
set pat {0BADC0DEDEADBEEF A5A5A5A55A5A5A5A}
set ok 1
if {$hbm eq ""} {
    puts "HBM_SKIPPED: no unambiguous HBM master (see PCIEEP_NOTE above)."
    set ok -1
} else {
for {set i 0} {$i < 2} {incr i} {
    set a [format %X [expr {0x1FFFFF000 + $i * 8}]]
    wr $hbm $a [lindex $pat $i]
}
for {set i 0} {$i < 2} {incr i} {
    set a [format %X [expr {0x1FFFFF000 + $i * 8}]]
    set gw [rd_words $hbm $a]
    set got [string toupper "[lindex $gw 1][lindex $gw 0]"]
    # NUMERIC compare.  This was `[string toupper $got] ne [string toupper
    # $want]`, comparing rd's DECIMAL output against a hex literal, so it could
    # never match and every word reported a mismatch whatever the memory held.
    # MEASURED 2026-08-29: it printed "wrote DEADBEEF read 3" and the run was
    # read as an HBM fault on evidence that could not distinguish one.
    set want [lindex $pat $i]
    if {$got ne $want} {
        puts "HBM_MISMATCH at 0x$a: wrote 0x$want read 0x$got"
        set ok 0
    }
}
}
if {$ok == -1} {
} elseif {$ok} {
    puts "HBM_OK scratch page 0x1FFFFF000 writes and reads back"
    puts "       (this address is in SAXI_16's half, so both stacks are mapped)"
} else {
    puts "PCIEEP_WARN: HBM readback mismatched.  HBM init may not have completed;"
    puts "             tcl/hbmdiag.tcl is the instrument for that."
}

# ---- 4. The DMA BRAM, over JTAG.  Same 64 KB the host reaches through
# /dev/xdma0_h2c_0 at file offset 0x2_0000_0000.  This is the ONLY way to tell
# "XDMA wrote the wrong bytes" from "the host read-back path is wrong": write a
# known pattern here from JTAG, read it from the host, and vice versa.  Unlike
# the HBM scratch page above it involves no memory controller at all, so a
# mismatch here cannot be blamed on HBM initialisation.
# Same four words the host writes, paired into 64-bit transactions.
set bpat {4A544147464B3333 FEDCBA9812345678}
set bok 1
if {$hbm eq ""} {
    puts "DMABRAM_SKIPPED: no unambiguous HBM master (see PCIEEP_NOTE above)."
    set bok -1
} else {
for {set i 0} {$i < 2} {incr i} {
    wr $hbm [format %X [expr {0x200000000 + $i * 8}]] [lindex $bpat $i]
}
for {set i 0} {$i < 2} {incr i} {
    set a [format %X [expr {0x200000000 + $i * 8}]]
    set gw [rd_words $hbm $a]
    set got [string toupper "[lindex $gw 1][lindex $gw 0]"]
    set want [lindex $bpat $i]
    if {$got ne $want} {
        puts "DMABRAM_MISMATCH at 0x$a: wrote 0x$want read 0x$got"
        set bok 0
    }
}
}
if {$bok == -1} {
} elseif {$bok} {
    puts "DMABRAM_OK 0x200000000 holds 464B3333 4A544147 12345678 FEDCBA98"
    puts "           Read the same four words from the host with:"
    puts "             dd if=/dev/xdma0_c2h_0 bs=16 count=1 skip=\$((0x200000000/16)) | xxd"
    puts "           Agreement proves the DMA target; disagreement localises the"
    puts "           fault to XDMA or the driver rather than to the fabric."
} else {
    puts "PCIEEP_WARN: the DMA BRAM did not read back over JTAG.  This is on the"
    puts "             same smartconnect as HBM but has no memory controller, so"
    puts "             a failure here and an HBM pass would be an interconnect or"
    puts "             address-decode fault, not a memory fault."
}

puts "PCIEEP_DONE"
close_hw_target
