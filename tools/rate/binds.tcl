# tools/rate/binds.tcl -- elaborate a top (RTL only, no synthesis) and print the properties
# of EVERY instance of each named entity; the generics are among them.
#   -tclargs <part> <filelist> <top> [NAME=VALUE ...] <entity> [<entity> ...]
# NAME=VALUE arguments are top-level generics, for a top the block design configures
# (fk33_engine: CONFIG.CB_STYLE, CONFIG.USE_XEXP_PORT in build_fk33_pcieep.tcl).
# Cells are selected by REF_NAME, not by name: in an RTL-elaborated design generate labels
# are joined with dots (MEASURED 2026-09-25: `u/gcr.gkvaxi.u_kv`), so a name pattern guesses.
# Teeth (plan Task 7): attn_kv_axi at the 9B card reads HEAD_DIM 256, KV_BLOCK 32, N_KVH 4.
lassign $argv part filelist top
set ents {}; set gens {}
foreach a [lrange $argv 3 end] { if {[string first = $a] > 0} { lappend gens -generic $a } else { lappend ents $a } }
set fh [open $filelist]; foreach f [split [string trim [read $fh]] "\n"] { read_vhdl -vhdl2008 $f }; close $fh
synth_design -rtl -top $top -part $part {*}$gens
foreach e $ents {
  set os [get_cells -quiet -hier -filter "REF_NAME == $e || ORIG_REF_NAME == $e"]
  if {[llength $os] == 0} { puts "BIND_MISSING $e"; continue }
  foreach o $os {
    foreach p [list_property $o] { puts "BIND $o $p [get_property $p $o]" }
  }
}
puts "BIND_DONE"
