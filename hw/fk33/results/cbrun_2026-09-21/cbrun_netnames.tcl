# TRACK CBRUN, 2026-09-21 -- name the codebook command nets, per arm, from the
# post-opt_design checkpoint each draw already wrote.
#
# WHY THIS EXISTS.  The coordinator's matvec_int4_desc_axi run measured the
# `new` arm's command-net fanout histogram as `109x1 49x12`: twelve of the
# thirteen command bits fell to 49 sinks as registered, and ONE did not.  A
# histogram cannot say WHICH, because sim/ooc_cbooc.tcl stores counts and not
# names.  This does, by opening the checkpoint rather than re-synthesising --
# the same netlist, so the answer is exact rather than merely equivalent.
#
# AND IT ADDS AN ARM-INDEPENDENT INSTRUMENT.  The `cbw_*`-name filter cannot
# measure the `fan` arm at all: there the RAM write ports are driven by the
# combinational `cbx_*` wires, so a name-based census of `cbw_*` reports the
# fanout of a DIFFERENT net and would silently look like a pass.  So the fanout
# is ALSO taken from the RAM cells' own input pins, which is where congestion
# actually lives and which needs no naming assumption of mine.
#
# NO HARDWARE.  open_checkpoint and report_* only.
proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}
set dcp [envor CBN_DCP ""]
set tag [envor CBN_TAG ""]
if {$dcp eq "" || $tag eq ""} { error "CBN_ABORT: CBN_DCP and CBN_TAG required" }
if {![file exists $dcp]} { error "CBN_ABORT: no checkpoint at $dcp" }

open_checkpoint $dcp
puts "CBN_BEGIN tag=$tag dcp=$dcp"

# ---------------------------------------------------------------------------
# A. THE COMMAND NETS, BY NAME.  Every net on a D pin of a cbw_* flop, with its
# FLAT_PIN_COUNT and the bit it carries, so the outlier is identified and not
# merely counted.  FLAT_PIN_COUNT counts the driver when the driver is a cell
# pin and not when it is a top-level port, so sinks are reported BOTH ways
# rather than picked.
# ---------------------------------------------------------------------------
set cbw [get_cells -hier -quiet -filter {NAME =~ *cbw_* && REF_NAME =~ FD*}]
puts "CBN_CBWCELLS tag=$tag n=[llength $cbw]"
if {[llength $cbw] > 0} {
    set dpins [get_pins -quiet -of_objects $cbw -filter {REF_PIN_NAME == D}]
    set dnets [get_nets -quiet -of_objects $dpins]
    puts "CBN_DNETS tag=$tag distinct=[llength $dnets]"
    foreach n $dnets {
        set fp [get_property -quiet FLAT_PIN_COUNT $n]
        # which cbw_* registers does it reach, and how many of each family
        set lp [get_pins -quiet -of_objects $n -filter {DIRECTION == IN}]
        set nv 0; set na 0; set nd 0; set nx 0
        foreach p $lp {
            set cn [get_property -quiet PARENT_CELL $p]
            if {$cn eq ""} { set cn $p }
            if {[string match "*cbw_v*" $cn]} { incr nv } \
            elseif {[string match "*cbw_a*" $cn]} { incr na } \
            elseif {[string match "*cbw_d*" $cn]} { incr nd } \
            else { incr nx }
        }
        set drv [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]
        set prt [get_ports -quiet -of_objects $n]
        puts "CBN_NET tag=$tag flat_pin_count=$fp loads=[llength $lp]\
 to_cbw_v=$nv to_cbw_a=$na to_cbw_d=$nd to_other=$nx\
 drivers=[llength $drv] ports=[llength $prt] name=$n"
    }
}

# ---------------------------------------------------------------------------
# B. THE RAM WRITE PORTS, NAME-INDEPENDENT.  For every RAM* cell of the
# codebook, the FLAT_PIN_COUNT of the net on each of its INPUT pins, as a
# histogram.  This is the instrument that works for all four arms, including
# `fan`, where the write ports are driven by cbx_* and a cbw_* filter measures
# the wrong net.
# ---------------------------------------------------------------------------
set cbram [get_cells -hier -quiet -filter {NAME =~ *cb_reg* && REF_NAME =~ RAM*}]
set cbff  [get_cells -hier -quiet -filter {NAME =~ *cb_reg* && REF_NAME =~ FD*}]
puts "CBN_CBCELLS tag=$tag ram=[llength $cbram] ff=[llength $cbff]"
set store $cbram
if {[llength $store] == 0} { set store $cbff }
if {[llength $store] > 0} {
    set ipins [get_pins -quiet -of_objects $store -filter {DIRECTION == IN}]
    set inets [get_nets -quiet -of_objects $ipins]
    array unset h
    set mx 0
    set fps {}
    if {[llength $inets] > 0 && [catch {set fps [get_property FLAT_PIN_COUNT $inets]}]} {
        set fps {}
        foreach n $inets { lappend fps [get_property -quiet FLAT_PIN_COUNT $n] }
    }
    foreach n $inets fp $fps {
        if {$fp eq "" || ![string is integer -strict $fp]} continue
        if {$fp > $mx} { set mx $fp }
        # bucket, so a 1,536-pin net and a 2-pin net are distinguishable without
        # printing 20,000 lines
        set b $fp
        if {![info exists h($b)]} { set h($b) 0 }
        incr h($b)
    }
    set hist {}
    set n_shown 0
    foreach k [lsort -integer -decreasing [array names h]] {
        if {$n_shown >= 12} { break }
        lappend hist "${k}x$h($k)"
        incr n_shown
    }
    puts "CBN_RAMIN tag=$tag store_cells=[llength $store] distinct_in_nets=[llength $inets]\
 max_flat_pin_count=$mx top_hist=\"[join $hist { }]\""
}

# TOTALS.  `fan` and `new` reported IDENTICAL values in all twenty summary
# fields, including lut1, lut2, carry8, WNS to three decimals and the endpoint
# count.  That is consistent with one netlist, and a total cell/net count is the
# cheapest check that can still tell them apart -- the combinational cbx_* alias
# either folded away entirely or it did not.
puts "CBN_TOTAL tag=$tag cells=[llength [get_cells -hier -quiet]]\
 nets=[llength [get_nets -hier -quiet]] pins=[llength [get_pins -hier -quiet]]"

# The census, repeated here so this file can be read on its own.
foreach {label pat} {
    cb_ram  {NAME =~ *cb_reg* && REF_NAME =~ RAM*}
    cb_ff   {NAME =~ *cb_reg* && REF_NAME =~ FD*}
    cbw_ff  {NAME =~ *cbw_* && REF_NAME =~ FD*}
    cbx_any {NAME =~ *cbx_*}
    cbr_ff  {NAME =~ *cbr_* && REF_NAME =~ FD*}
    muxf8   {REF_NAME == MUXF8}
    muxf7   {REF_NAME == MUXF7}
    ramd32  {REF_NAME == RAMD32}
    rams32  {REF_NAME == RAMS32}
    ram32m16 {REF_NAME == RAM32M16}
} {
    puts "CBN_CENSUS tag=$tag $label=[llength [get_cells -hier -quiet -filter $pat]]"
}

close_project
# THE SENTINEL.  Nothing may follow it.
puts "CBN_DONE $tag"
