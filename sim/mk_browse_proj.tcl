# mk_browse_proj.tcl -- a Vivado PROJECT you open in the GUI to look at the
# design as blocks with ports.  Built 2026-08-30 at Oren's request.
#
# WHAT THIS GIVES YOU, and it is the RTL ELABORATED view, not a block design:
# open the project, click "Open Elaborated Design" in the Flow Navigator, then
# Schematic.  Every VHDL entity appears as a block with its input and output
# ports named, the hierarchy is expandable, and double-clicking a block
# descends into it.  Click any block and "Go to Source" opens the .vhd.
#
# WHY NOT AN IP-INTEGRATOR BLOCK DESIGN.  A BD canvas would need each of the
# 93 entities packaged as IP or added as a module reference and then wired by
# hand or by script, and the wiring would be a SECOND description of a
# structure the VHDL already states.  That is a lot of work and it creates a
# thing that can DISAGREE with the RTL.  The elaborated view is generated FROM
# the RTL, so it cannot drift.  The shell (PCIe, HBM, XDMA) genuinely is a
# block design and is already viewable -- see BROWSE_TARGET=shell below.
#
# NO HARDWARE.  This script creates a project and adds files.  It does not
# elaborate, synthesise, open a target, program a device, or touch /dev/xdma*.
# Elaboration is what YOU do in the GUI, deliberately, because that is the
# step with a real memory cost.
#
# MEMORY.  create_project + add_files is seconds and well under 2 GB.  The
# ELABORATION you trigger in the GUI is the expensive part: llama_top defaults
# to the real 9B shape (SHAPE := mk_shape(MODEL, NCARDS)), and a composed
# place-and-route of this design has been MEASURED leaving 233 MB free while
# alone on this box.  Elaboration is much lighter than that, but check `free`
# and do not open it beside a running synthesis.
#
# USAGE:
#   vivado -mode batch -source sim/mk_browse_proj.tcl
#   vivado -mode batch -source sim/mk_browse_proj.tcl -tclargs shell
#
#   BROWSE_TARGET=model   (default) top = llama_top.  All four subsystems:
#                         A matvec, B gated deltanet, C attention, D sequencer.
#   BROWSE_TARGET=card    top = compose4_top.  The card composition.
#   BROWSE_TARGET=shell   prints the path of the EXISTING shell block design
#                         and creates nothing.
#   BROWSE_DIR=<path>     where to put it (default /mnt/storage/llama-browse)

set target "model"
if {[info exists ::env(BROWSE_TARGET)]} { set target $::env(BROWSE_TARGET) }
if {$::argc > 0} { set target [lindex $::argv 0] }

set outdir "/mnt/storage/llama-browse"
if {[info exists ::env(BROWSE_DIR)]} { set outdir $::env(BROWSE_DIR) }

set repo [file normalize [file join [file dirname [info script]] ..]]

if {$target eq "shell"} {
    puts "The shell IS a block design already.  Open either of these and then"
    puts "Open Block Design in the Flow Navigator:"
    foreach x [glob -nocomplain $repo/hw/fk33/*/*.xpr] { puts "  $x" }
    puts ""
    puts "That canvas shows the PCIe endpoint, XDMA, the HBM controller and the"
    puts "AXI interconnect as wired blocks.  It does NOT show our RTL internals;"
    puts "for those use BROWSE_TARGET=model."
    return
}

# THE SHAPE MATTERS AND THE PRODUCTION DEFAULT DOES NOT ELABORATE.
# MEASURED 2026-08-30: `llama_top` at its default 9B shape CRASHES Vivado.  Its
# region scratch (rtl/llama_top.vhd:1085) is a FLAT `buf_t(0 to NREGION*REGMAX-1)`
# with 16 access ports; at 9B that is 14 * 12288 * 16 = 2,752,512 bits, which
# Vivado cannot infer as RAM, cannot dissolve, and SEGFAULTS attempting:
#   ERROR: [Synth 8-3391] ... Failed to dissolve the memory into bits because
#   the number of bits (2752512) is too large.
# followed by SIGSEGV in HOptDfg::dissolveRam (hs_err_pid478670.log).
#
# So `model` defaults to the SCALED wrapper, which is generated mechanically
# from llama_top's own entity by sim/mk_browse_wrapper.py -- same hierarchy,
# same 89 ports, only counts and widths shrink.  MEASURED: elaborates in 57 s
# to 172,827 cells / 1,186,930 nets, peak 5 GB, zero errors.
#
#   BROWSE_SHAPE=scaled  (default) top = llama_top_browse
#   BROWSE_SHAPE=real    top = llama_top.  KNOWN TO CRASH.  Kept because a
#                        future card-level top will not have this memory, and
#                        the day it elaborates is a result worth having.
set shape "scaled"
if {[info exists ::env(BROWSE_SHAPE)]} { set shape $::env(BROWSE_SHAPE) }

set wrapper "/mnt/storage/llama-browse/llama_top_browse.vhd"

switch -- $target {
    model {
        if {$shape eq "real"} {
            set top "llama_top"
            puts "WARNING: BROWSE_SHAPE=real.  This is MEASURED to crash Vivado in"
            puts "         HOptDfg::dissolveRam at 2,752,512 bits.  See the header."
        } else {
            if {![file exists $wrapper]} {
                error "wrapper missing: $wrapper
Run: python3 sim/mk_browse_wrapper.py"
            }
            set top "llama_top_browse"
        }
    }
    card  { set top "compose4_top" }
    default { error "BROWSE_TARGET must be model, card or shell (got '$target')" }
}

set proj "llama_browse_$target"
file mkdir $outdir
create_project -force $proj $outdir/$proj -part xcvu33p-fsvh2104-2L-e

# rtl/ is the design.  hw/fk33/rtl/ carries the card wrappers and is needed for
# the card target; adding it for both is harmless because an unreferenced entity
# is simply not elaborated.
set srcs [glob -nocomplain $repo/rtl/*.vhd]
set fk33 [glob -nocomplain $repo/hw/fk33/rtl/*.vhd]
if {[llength $fk33] > 0} { set srcs [concat $srcs $fk33] }
if {$top eq "llama_top_browse"} { lappend srcs $wrapper }
add_files -norecurse $srcs
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top $top [current_fileset]

# Do NOT let Vivado reorder the top away from us.  update_compile_order is what
# picks a top when one is not pinned, and it has picked a testbench before.
update_compile_order -fileset sources_1
set_property top $top [current_fileset]

puts ""
puts "PROJECT CREATED"
puts "  [llength $srcs] VHDL files, top = $top, part xcvu33p-fsvh2104-2L-e"
puts "  $outdir/$proj/$proj.xpr"
puts ""
puts "TO LOOK AT IT:"
puts "  vivado $outdir/$proj/$proj.xpr &"
puts "  then Flow Navigator -> RTL ANALYSIS -> Open Elaborated Design"
puts "  then Schematic.  Expand blocks with the + on each, or double-click."
puts ""
puts "BROWSE_PROJ_OK $outdir/$proj/$proj.xpr"
