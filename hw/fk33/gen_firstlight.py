#!/usr/bin/env python3
"""Derive hw/fk33/build_fk33_firstlight.tcl from SQRL's fk33_example.tcl.

A GENERATOR rather than a checked-in fork, so that upstream fixes are not lost:
SQRL_FK33 is a third-party repo we do not control, and a hand-edited copy would
silently diverge the first time it changes.  Re-run this after pulling that repo
and diff the result.

Every substitution below is a change we NEED and upstream will not make; each is
explained in the generated header.  If a replacement stops matching, this script
fails loudly rather than emitting a file that quietly lacks the change -- which
matters most for the speed grade, where a silent revert to -2 would mean signing
off timing against silicon we do not own.
"""
import os
import re
import sys

SRC = os.path.expanduser("~/GitHub/SQRL_FK33/projects/fk33_example.tcl")
DST = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "build_fk33_firstlight.tcl")
PART = "xcvu33p-fsvh2104-2L-e"

HEADER = f'''# GENERATED from SQRL_FK33/projects/fk33_example.tcl by hw/fk33/gen_firstlight.py
# -- do not hand-edit; regenerate so upstream fixes are not lost.
#
# FIRST-LIGHT bitstream for the FK33: JTAG only, no PCIe.
# Four changes from upstream, each of which would otherwise stop the build or
# produce the wrong artifact:
#
#  1. EnablePCIe 0.  docs/fpga-hardware-recon.md establishes that both planned
#     experiments are reachable over JTAG alone, so first light needs nothing
#     resolved about PCIe, ACS or P2P.  Fewer moving parts on the first power-on.
#
#  2. The Vivado version gate is removed.  Upstream hard-errors unless the tool
#     is exactly 2022.2; this install is 2023.2 and installing a second Vivado
#     is ~100 GB.  This is the risky change: block designs carry IP versions, so
#     an explicit upgrade_ip pass is added below and its output must be read,
#     not assumed.
#
#  3. Part forced to {PART}, NOT the -2-e upstream hardcodes.
#     Upstream contradicts its own board file, which says -2L
#     (board_files/sqrl_fk33/1.1/board.xml).  -2 is the FASTER grade, so
#     building for it and deploying on -2L silicon signs timing off against
#     hardware we do not have.  -2L is the conservative direction.  Settle it
#     empirically once the card is in: Vivado hardware manager reports the real
#     part from the IDCODE, and if it is genuinely -2 this can be relaxed for
#     free headroom.
#
#  4. Upstream never builds anything -- it creates the project and stops.
#     Synthesis, implementation and write_bitstream are appended.
#
'''

SUBS = [
    ("set EnablePCIe 1", "set EnablePCIe 0"),
    ('''if {[string compare [version -short] 2022.2] != 0} {
    return -code error [format "Unsupported Vivado version. Try 2022.2"]
}''',
     '''# version gate removed -- see header note 2
puts "INFO: building with Vivado [version -short] (upstream targets 2022.2)"'''),
    ('create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2-e"',
     f'create_project $ProjectName ./$ProjectName -part "{PART}"'),
    # 5. util_ds_buf 2.1 -> 2.2 in the NON-PCIe branch.  Upstream asks for 2.2 in
    #    the PCIe branch and 2.1 here, and 2023.2's catalog only has 2.2, so the
    #    2.1 request yields a locked IP whose parameter propagation then fails
    #    with "Parameter IBUF_OUT.CLK_DOMAIN not found".  That the stale version
    #    sits ONLY in the else branch is evidence upstream never exercised
    #    EnablePCIe 0 -- which is exactly the path first light depends on, so
    #    expect more of these rather than assuming this was the last one.
    ("create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.1 util_ds_buf_1",
     "create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_1"),
    # 7. scriptPath/sourceRoot are derived from [info script], which upstream
    #    can do because its script SITS IN the repo beside fk33_example.xdc.
    #    The generated copy lives in this repo instead, so those paths must be
    #    pinned back at the upstream checkout or the XDC is not found. Pinned
    #    rather than copied, so the constraints stay single-sourced upstream.
    ('set scriptPath [file dirname [file normalize [info script]]]\nset sourceRoot [join [lrange [file split [file dirname [info script]]] 0 end-2] "/"]',
     '# paths pinned to the upstream checkout -- see header note 7\nset scriptPath "/home/orencollaco/GitHub/SQRL_FK33/projects"\nset sourceRoot "/home/orencollaco/GitHub/SQRL_FK33"'),
]

# 6. exclude_bd_addr_seg calls name a -target_address_space that may not exist.
#    With EnablePCIe 0 there is no xdma, so `[get_bd_addr_spaces xdma/M_AXI]`
#    returns empty and Vivado fails with "Please specify an address space when
#    excluding slave segment".  Upstream never guards that block with
#    EnablePCIe -- more evidence the non-PCIe path was never run.  Rather than
#    delete the lines (which would silently drop the jtag_hbm exclusions too if
#    upstream reorders them), route every call through a helper that no-ops when
#    the space is absent, so whichever master exists gets its exclusions and the
#    other is skipped.
EXCLUDE_RE = re.compile(
    r"exclude_bd_addr_seg \[get_bd_addr_segs ([^\]]+)\] "
    r"-target_address_space \[get_bd_addr_spaces ([^\]]+)\]")

HELPER = '''
# injected by gen_firstlight.py -- see header note 6
proc exclude_seg_if {seg space} {
    set sp [get_bd_addr_spaces -quiet $space]
    if {[llength $sp] == 0} {
        return
    }
    set sg [get_bd_addr_segs -quiet $seg]
    if {[llength $sg] == 0} {
        return
    }
    exclude_bd_addr_seg $sg -target_address_space $sp
}
'''

TAIL = '''

# ---------------------------------------------------------------- build
# IP upgrade first, and REPORT it.  Crossing 2022.2 -> 2023.2 can revise the HBM
# controller, the smartconnect and xdma; a stale IP either fails to generate or,
# worse, generates with different defaults.  report_ip_status output is the
# thing to read if this build misbehaves.
puts "==== IP status before upgrade ===="
report_ip_status
set stale [get_ips -filter {IS_LOCKED == 1 || UPGRADE_VERSIONS != ""}]
if {[llength $stale] > 0} {
    puts "==== upgrading [llength $stale] IP ===="
    upgrade_ip $stale
    report_ip_status
}

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "SYNTH FAILED -- see the run log"
}
puts "==== synthesis done ===="

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "IMPL FAILED -- see the run log"
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
report_utilization -file fk33_firstlight_util.rpt

set bit [glob -nocomplain ./$ProjectName/$ProjectName.runs/impl_1/*.bit]
if {[llength $bit] == 1} {
    puts "FK33_BITSTREAM [lindex $bit 0] ([file size [lindex $bit 0]] bytes)"
} else {
    puts "FK33_BITSTREAM MISSING"
}
puts "FK33_BUILD_DONE"
'''

if not os.path.exists(SRC):
    sys.exit(f"upstream script not found: {SRC}")
s = open(SRC).read()
for old, new in SUBS:
    if old not in s:
        sys.exit(f"ABORT: upstream no longer contains:\\n{old}\\n"
                 "Re-read fk33_example.tcl and update this generator; emitting "
                 "the file without this change would be worse than failing.")
    s = s.replace(old, new, 1)
n_ex = len(EXCLUDE_RE.findall(s))
if n_ex == 0:
    sys.exit("ABORT: no exclude_bd_addr_seg calls matched; the address-space "
             "guard would be silently absent.")
s = EXCLUDE_RE.sub(r"exclude_seg_if \1 \2", s)
# helper must be defined before first use
s = s.replace("create_bd_design \"bd\"", HELPER + "\ncreate_bd_design \"bd\"", 1)
print(f"  guarded {n_ex} exclude_bd_addr_seg calls")
open(DST, "w").write(HEADER + s + TAIL)
print(f"wrote {DST}")
