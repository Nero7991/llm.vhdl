#!/bin/bash
# hw/jc/link/run_aurora_sim.sh -- xsim of tb_jc_aurora_link through a Vivado project
# (plan 2026-11-04 Task 5 Step 7). No hardware. One Vivado per box: the caller checks presence.
# usage: run_aurora_sim.sh <ip_out_dir (l1|l4, sim mode)> <nlanes> <perm> <work_dir>
# prints ^AURSIM_PASS or ^AURSIM_FAIL (the bench's own line, or the harness's when it never ran)
set -u
IPOUT=$1; NL=$2; PERM=$3; WORK=$4
R=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)   # finding 6: this worktree
mkdir -p "$WORK"
cat > "$WORK/sim.tcl" <<TCL
create_project -force s $WORK/prj -part xcvu35p-fsvh2104-2L-e
add_files [glob $IPOUT/prj/aur.srcs/sources_1/ip/jc_aurora/jc_aurora.xci]
add_files -fileset sim_1 [list $R/rtl/jc_loader_pkg.vhd $R/rtl/jc_link_pkg.vhd $R/rtl/jc_link_tx.vhd \
  $R/rtl/jc_link_rx.vhd $R/hw/jc/link/rtl/jc_aurora_wrap_l$NL.vhd $R/hw/jc/link/sim/tb_jc_aurora_link.vhd]
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1] *.vhd]
set_property top tb_jc_aurora_link [get_filesets sim_1]
set_property generic "NLANES=$NL PERM=$PERM" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
close_sim
TCL
vivado -mode batch -nojournal -log "$WORK/vivado.log" -source "$WORK/sim.tcl" > "$WORK/vivado.out" 2>&1
L=$(find "$WORK/prj" -name simulate.log | head -1)
if [ -n "$L" ] && grep -qE '^(Note: )?AURSIM_(PASS|FAIL)' "$L"; then
  grep -E '^(Note: )?AURSIM_(PASS|FAIL)' "$L" | sed 's/^Note: //'
else
  echo "AURSIM_FAIL harness: no bench verdict (see $WORK/vivado.log)"
fi
