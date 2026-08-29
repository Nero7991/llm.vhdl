# TEETH CHECK for `used_in_synthesis false` on hw/fk33/fk33_pblock.xdc.
#
# The claim in the file's own header and in gen_pcieep.py is:
#   "bd_i/eng/inst/eng/dut/core is a path in the LINKED design and does not
#    exist during synthesis; get_cells would return nothing and
#    add_cells_to_pblock errors on an empty object."
#
# A build that passes with the property set proves nothing about that claim:
# a guard never shown to fail has not been shown to work.  This runs the
# CONTROL -- the same XDC WITH used_in_synthesis left at its default -- on a
# trivial top, and records what Vivado actually does.  Two outcomes are
# interesting and both get recorded:
#   * synthesis fails            -> the claim is right, the property is
#                                   load-bearing
#   * synthesis passes with a
#     warning                    -> the claim overstates it; the property is
#                                   still correct but for a weaker reason
#
# No hardware.  Trivial design, seconds of synthesis.

set outdir [lindex $argv 0]
set pxdc   [lindex $argv 1]

file mkdir $outdir
cd $outdir

# A top with nothing in it.  The point is the constraint file, not the logic.
set fh [open tiny.v w]
puts $fh "module tiny(input wire a, output reg b); always @* b = ~a; endmodule"
close $fh

create_project tp ./tp -part xcvu33p-fsvh2104-2L-e -force
add_files -norecurse ./tiny.v
set_property top tiny [current_fileset]
add_files -fileset constrs_1 -norecurse $pxdc

# 1. What is the DEFAULT?  If it were already false, the set_property in the
#    build script would be decoration.
puts "TEETH_UIS default used_in_synthesis   = [get_property used_in_synthesis [get_files $pxdc]]"
puts "TEETH_UIS default used_in_implementation = [get_property used_in_implementation [get_files $pxdc]]"

# 2. THE CONTROL.  Leave it at the default and synthesise.
puts "TEETH_UIS === control: synthesising WITH the pblock XDC in synthesis ==="
launch_runs synth_1 -jobs 2
wait_on_run synth_1
puts "TEETH_UIS control PROGRESS=[get_property PROGRESS [get_runs synth_1]] STATUS=[get_property STATUS [get_runs synth_1]]"
set rl ./tp/tp.runs/synth_1/runme.log
if {[file exists $rl]} {
    set fh [open $rl r]; set txt [read $fh]; close $fh
    foreach ln [split $txt "\n"] {
        if {[regexp {^(ERROR|CRITICAL WARNING|WARNING).*(pblock|get_cells|Vivado 12-|Common 17-)} $ln]} {
            puts "TEETH_UIS control| $ln"
        }
    }
}

# 3. THE TREATMENT.  Set the property the build script sets, and synthesise the
#    identical design again.
puts "TEETH_UIS === treatment: used_in_synthesis false, same design ==="
set_property used_in_synthesis false [get_files $pxdc]
puts "TEETH_UIS treatment used_in_synthesis = [get_property used_in_synthesis [get_files $pxdc]]"
reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1
puts "TEETH_UIS treatment PROGRESS=[get_property PROGRESS [get_runs synth_1]] STATUS=[get_property STATUS [get_runs synth_1]]"
if {[file exists $rl]} {
    set fh [open $rl r]; set txt [read $fh]; close $fh
    foreach ln [split $txt "\n"] {
        if {[regexp {^(ERROR|CRITICAL WARNING).*(pblock|get_cells|Common 17-)} $ln]} {
            puts "TEETH_UIS treatment| $ln"
        }
    }
}
puts "TEETH_UIS_DONE"
