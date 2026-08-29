#!/usr/bin/env python3
"""Classify ONE ghdl -r run log into three verdicts, not two.

WHY THIS FILE EXISTS.  Every sim/mutate_attn_*.sh and sim/mutate_seq_*.sh
judged a mutation with the shape

    ghdl -r ... > run.log 2>&1 && grep -q PASS run.log

which has exactly two outcomes, and therefore cannot distinguish the two
things that matter most:

  * the CHECKER ran, reached its own verdict, and rejected the mutant, and
  * the run DIED -- an elaboration error, a language bound check, the DUT's
    own assert, a wedge to --stop-time -- so the checker never reached a
    verdict at all.

The second scored as a KILL.  It is not one.  Nothing was measured about the
checker's resolution; the mutation was stopped by the language, by the design's
own internal assert, or by the clock running out.  A harness that cannot tell a
kill from a crash has not been shown to measure anything, and the kill ratios it
publishes are not readable at face value.

THE THREE VERDICTS, and the rule for each, stated before any log is read:

  PASS    the bench printed its own PASS verdict line.  The mutant survived
          this configuration.

  KILLED  the CHECKER noticed.  Either the bench printed its own FAIL verdict
          line, or the log carries a ghdl diagnostic whose SOURCE FILE is the
          testbench itself.  The second clause matters: several benches count
          errors as they go and assert at severity failure without ever
          reaching the FAIL line (tb_attn_kv_seam has no FAIL line at all, only
          a watchdog and a set of severity-failure guards), and a coverage
          assertion firing IS the checker noticing.

  ABORT   the run never reached a verdict the checker owns.  A reason is
          always reported, because the reasons are not equivalent:

            ELAB       analysis or elaboration failed
            LANG       a language check fired: bound, index, range, overflow,
                       null access, division by zero.  The mutation was caught
                       by VHDL, not by the bench.
            DUTASSERT  an assert inside the design under test fired.  This is
                       the design's own internal consistency check.  It is a
                       real signal and it is NOT the bench's checker, so it is
                       counted apart from one.
            WEDGE      the simulator hit --stop-time with no verdict: the
                       mutant deadlocked.  Real behaviour, but the value check
                       never ran, so nothing is known about what it would have
                       said.
            TIMEOUT    the external timeout(1) killed the run.
            NOVERDICT  the run exited without printing any verdict and without
                       any of the above.  Look at the log by hand.

WHAT THIS DOES NOT DO.  It does not decide whether an ABORT is "really" a kill.
That is a judgement about the mutation, and it belongs in the harness's prose
next to the mutation, not in a classifier.  What it does is stop the two from
being added together silently.

Usage:
  python3 sim/mutverdict.py <run.log> <tb_entity> [exit-status] [bench-file ...]

The trailing bench-file arguments name ADDITIONAL source files that are part of
the checker, beyond <tb_entity>.vhd.  They matter: sim/tb_attn_kv_axi.vhd is a
five-line verdict wrapper and every protocol check for that unit lives in
sim/kv_axi_harness.vhd ("its three AXI slaves, its consumer model and its
checker", that file's own header).  MEASURED 2026-08-29: without naming it,
13 of sim/mutate_attn_kv_axi.sh's 28 rows were classified ABORT:DUTASSERT when
the assert that fired was the CHECKER's, and the harness's kill ratio read
11 of 28 instead of 24 of 28.  A classifier that is wrong in the safe direction
is still wrong.

Prints one token on stdout:  PASS | KILLED | ABORT:<REASON>
Exit status is always 0 unless the arguments are wrong; the verdict is the
value, and a nonzero exit here would be indistinguishable from a run failure.
"""
import os
import re
import sys

if len(sys.argv) < 3:
    sys.stderr.write("usage: mutverdict.py <run.log> <tb_entity> [rc]\n")
    sys.exit(2)

log_path, tb = sys.argv[1], sys.argv[2]
rc = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] != "" else None
extra = [a if a.endswith(".vhd") else a + ".vhd" for a in sys.argv[4:] if a]

if not os.path.exists(log_path):
    print("ABORT:NOLOG")
    sys.exit(0)

try:
    text = open(log_path, errors="replace").read()
except OSError:
    print("ABORT:NOLOG")
    sys.exit(0)

# The verdict lines.  Two spellings are in use across the benches and both are
# accepted, deliberately, rather than normalised: rewriting a bench to suit a
# harness is how a harness stops measuring the bench.
#   "tb_attn_recip: PASS -- ..."      (most)
#   "tb_attn_rope PASS: ..."          (tb_attn_rope, tb_attn_rescale)
pass_re = re.compile(r"%s\s*:?\s*PASS\b" % re.escape(tb))
fail_re = re.compile(r"%s\s*:?\s*FAIL\b" % re.escape(tb))

if pass_re.search(text):
    print("PASS")
    sys.exit(0)

if fail_re.search(text):
    print("KILLED")
    sys.exit(0)

# A ghdl diagnostic line looks like
#   sim/tb_attn_recip.vhd:208:11:@595ns:(report error): case 0 head 0: ...
# The FILE is what tells us who noticed.  Matched without anchoring to the
# start of the path, because different harnesses analyse the bench under
# different working directories.
diag_re = re.compile(
    r"(?P<file>[^\s:]*\.vhd):\d+:\d+:@[^:]*:\((?:report|assertion) "
    r"(?:error|failure)\)")
bench_files = [tb + ".vhd"] + extra

diags = list(diag_re.finditer(text))
if any(any(d.group("file").endswith(b) for b in bench_files) for d in diags):
    print("KILLED")
    sys.exit(0)

# From here down the checker did not speak.  Work out why.
low = text.lower()
if ("error during elaboration" in low or "cannot elaborate" in low
        or "compilation error" in low or "unit not found" in low
        or "has not been analysed" in low):
    print("ABORT:ELAB")
    sys.exit(0)

# NOTE the spellings here were MEASURED against real ghdl-mcode output, not
# guessed.  The one that mattered is "index (32) out of bounds (0 to 31)":
# a first draft matched the literal "index out of bounds" and missed it because
# of the parenthesised value, so sim/mutate_attn_rope.sh's P18 -- which is
# killed by the LANGUAGE, at rtl/attn_rope.vhd:482, before tb_attn_rope prints
# anything at all -- came back NOVERDICT instead of LANG.
if re.search(r"(bound check failure|index check failure|range check failure|"
             r"overflow check failure|discrete type check failure|"
             r"length check failure|null access|access check failure|"
             r"division by zero|out of bounds|out of range|"
             r"index check failed|bound check failed)", low):
    print("ABORT:LANG")
    sys.exit(0)

if diags:
    src = os.path.basename(diags[0].group("file"))
    print("ABORT:DUTASSERT(%s)" % src)
    sys.exit(0)

if "simulation stopped by --stop-time" in low:
    print("ABORT:WEDGE")
    sys.exit(0)

if rc in (124, 137, 152):
    print("ABORT:TIMEOUT")
    sys.exit(0)

print("ABORT:NOVERDICT")
