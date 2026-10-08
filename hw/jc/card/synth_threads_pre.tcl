# hw/jc/card/synth_threads_pre.tcl -- STEPS.SYNTH_DESIGN.TCL.PRE for every synthesis run of
# the JC card build. Each synth_design otherwise forks up to 8 helper vivados, uncounted in
# its own reported peak; two IP runs overlapping drove jccard3/jccard4 (2026-10-07) out of
# swap. Two helpers per run.
set_param synth.maxThreads 2
set_param general.maxThreads 2
