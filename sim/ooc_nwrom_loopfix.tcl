# ooc_nwrom_loopfix.tcl -- TRACK NWROM, 2026-08-29.
#
# THE ONE LINE THAT MAKES THE COMMITTED `NORM_W_IMAGE` LOADER ELABORATE.
#
# MEASURED: at the real 9B shape (65 norm ops x 4096 elements, one 4-hex-digit
# int16 per line) `rtl/llama_top.vhd`'s `nw_count` runs its
# `while not endfile(fh) loop` 266,240 times, and Vivado's default elaboration
# loop limit is 65,536:
#
#   ERROR: [Synth 8-403] loop limit (65536) exceeded [...:187]
#   ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment
#   ERROR: [Synth 8-285] failed synthesizing module 'ooc_normadapt'
#
# The second error is a consequence of the first, not a second fault.
#
# This wrapper raises that limit and then sources TRACK LUTDIET's
# `sim/ooc_lutdiet_ports.tcl` UNMODIFIED, so every flag, the part, the period
# and the census are LUTDIET's and the resulting numbers stay comparable with
# every other area figure in this project.  The ONLY difference from a plain
# LUTDIET run is the parameter below.
#
# NO HARDWARE.  synth_design and report_* only.

set_param synth.elaboration.rodinMoreOptions \
    {rt::set_parameter maxLoopLimit 4000000}
puts "NWROM_LOOPLIMIT_RAISED 4000000"

source [file join [file dirname [info script]] ooc_lutdiet_ports.tcl]
