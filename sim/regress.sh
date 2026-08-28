#!/usr/bin/env bash
# sim/regress.sh -- ONE verdict for every testbench in sim/tb_*.vhd.
#
# WHY THIS EXISTS.  65 testbenches in sim/, 80 files in rtl/, and about twenty
# run_*.sh / mutate_*.sh scripts, each of which knows how to build exactly one
# unit.  Nothing ran them all, so verification was whatever anyone happened to
# remember, and shared units -- gdn_conv, rmsnorm_bf and gdn_emit_chain are
# each consumed by several subsystems -- were changed by one workstream and
# spot-checked by another.  That is the shape of a cross-subsystem regression
# that escapes.  This script runs everything, always, and returns non-zero if
# anything is not demonstrably green.
#
#   bash sim/regress.sh                 # full run, every testbench
#   bash sim/regress.sh --quick         # pre-commit subset, 36 s at --jobs 3
#   bash sim/regress.sh --jobs 4        # more parallelism (default 2)
#   bash sim/regress.sh --only gdn      # only testbenches matching a pattern
#   bash sim/regress.sh --list          # print the plan, run nothing
#   bash sim/regress.sh --coverage      # only the RTL-without-a-testbench report
#   bash sim/regress.sh --keep          # keep the scratch tree for post-mortem
#
# ---------------------------------------------------------------------------
# THE THINGS THIS GETS RIGHT, AND WHY EACH ONE IS HERE
# ---------------------------------------------------------------------------
#
# 1. GHDL HERE IS THE MCODE BACKEND.  `ghdl -e` produces NO binary and exits 0.
#    A runner built on `-e && ./tb` therefore reports a green build and runs
#    nothing.  This has already cost this project time; see the header of
#    sim/run_gdn_block.sh.  `ghdl -r <entity>` is run directly, always.
#
#    Related trap, and it bit this script during bring-up: the top-level entity
#    is NOT always the file stem.  sim/tb_rope_ps.vhd declares `entity tb_rope`,
#    sim/tb_rmsnorm_ps.vhd declares `entity tb_rmsnorm`, and five others do the
#    same.  Running the stem gives "cannot find entity or configuration", which
#    reads like a broken analysis.  The entity name is parsed out of the file.
#
# 2. ANALYSIS ORDER IS DERIVED, NOT LISTED.  A hardcoded order rots the moment
#    somebody adds a package.  Every rtl/, sim/ and sim/micro/ source is parsed
#    for the design units it DEFINES (entity/package) and the ones it
#    REFERENCES (`use work.X`, `entity work.X`, and component instantiation),
#    and the per-testbench closure is emitted in topological order.  The only
#    hardcoded part is a tie-break that pulls fixed_luts_pkg, fixed_pkg,
#    util_pkg and model_cfg_pkg to the front when the graph leaves them
#    unordered relative to each other; every real edge still comes from the
#    files.  A dependency cycle is reported as a SKIP, not silently ignored.
#
# 3. -frelaxed IS PASSED TO BOTH -a AND -r, UNCONDITIONALLY.  tb_rmsnorm_bf
#    uses non-protected shared variables; giving the flag to `-a` alone leaves
#    `-r` re-elaborating (mcode elaborates at run time) and failing with
#    analysis errors and no simulation, which reads as a broken testbench.
#    Detecting the need per file is possible but pointless: -frelaxed relaxes
#    LRM strictness, it does not change simulation semantics and it cannot
#    suppress an assertion, so applying it everywhere is strictly safer than
#    any list and cannot rot.  Same reasoning for --max-stack-alloc=0, which
#    several testbenches need because they build their vector tables as
#    function-local temporaries and ghdl-mcode's 128 KB default rejects them
#    with "declaration of a too large object" rather than a VHDL error.
#
# 4. EVERY TEST GETS ITS OWN WORKING DIRECTORY, POPULATED.  Testbenches open
#    vector files by bare name ("gdn_emit_chain_vec.txt") and golden files as
#    "../mem/golden/...".  Run from the wrong place they abort with "cannot
#    open vectors", which is a spurious failure.  Each test runs in
#    $SCRATCH/<tb>/run with every non-VHDL file in sim/ symlinked in and
#    $SCRATCH/<tb>/mem -> $REPO/mem, so both forms resolve.  That is also what
#    makes parallelism safe: no two tests share a workdir or a GHDL library.
#    Nothing is ever written into sim/.
#
# 5. GENERICS, STOP-TIMES AND GENERATED VECTORS ARE LIFTED FROM THE EXISTING
#    SCRIPTS, not reinvented.  See the EXTRAS tables below; each row cites the
#    run_*.sh or mutate_*.sh it came from.  Six vector files are NOT committed
#    and are produced by a C generator in ref/; those are built into the test's
#    own workdir.  A testbench whose vector file is missing and whose generator
#    is not in the table is still handled: the vector name is parsed out of the
#    testbench and ref/<stem>.c is built with its own defaults.  That is what
#    lets a testbench added by another workstream today run without an edit
#    here -- tb_attn_twiddle appeared mid-development and needed no row.
#
# 6. A VERDICT COMES FROM EVIDENCE, NOT FROM AN EXIT CODE ALONE.  This repo has
#    had an assertion at `severity note`: a genuine defect printed and the run
#    exited 0 (sim/tb_b_audit_ser_handshake.vhd line 203 documents the case).
#    A test is PASS only if it exits 0, prints NO failure marker, AND prints a
#    recognised success marker.  A run that produces no output at all is a
#    FAILURE, not a pass.  A run that produces output with no trustworthy
#    marker either way is NOVERDICT and counted as a failure -- it is not
#    evidence of anything.  Four testbenches in this repo are genuinely not
#    self-checking (they dump values for the netlist-compare flow, or measure
#    cycles); they are declared NOCHECK below, with the reason, and are
#    reported in their own bucket rather than being quietly counted as passes.
#
# 7. TIMEOUTS ARE REPORTED SEPARATELY FROM FAILURES.  They mean different
#    things: a timeout is usually an unguarded clock or a deadlock, a failure
#    is usually arithmetic.  Four testbenches in this project once ran forever
#    on an unguarded clock, one of them for 4h58m at 99.5% CPU.
#
# 8. PARALLELISM IS CONSERVATIVE BY DEFAULT.  --jobs defaults to 2 because this
#    workstation regularly has a Vivado synthesis running, and Vivado is the
#    memory hog that has already triggered a systemd-oomd kill of the whole
#    session cgroup.  Raise it when the box is idle.
#
# ---------------------------------------------------------------------------
# WHAT --quick SKIPS, AND WHY.  --quick IS NOT COVERAGE.
# ---------------------------------------------------------------------------
# --quick runs the fast unit testbenches only.  MEASURED on this workstation at
# --jobs 3: 36 s wall (32 PASS, 3 NOCHECK) against 124 s for the full run on an
# idle box.  Full-run wall time is dominated by tb_engine_dump and swings a lot
# with machine load -- the same run took over 20 minutes with a Vivado
# synthesis competing for the box, so do not treat 124 s as a budget.  --quick
# exists for the minute before a commit and it is NOT a substitute for a full
# run.  It deliberately omits, by name:
#
#   tb_gdn_block                the six-unit top level, minutes per skew point
#   tb_gdn_emit_chain           four units and four seams
#   tb_gdn_recur_pipe           384 cases at DIM=128
#   tb_gdn_y_emit               24 heads x 128 elements over two blocks
#   tb_engine_dump              the whole shared-datapath engine, token loop
#   tb_matvec_int4              full AXI weight-stream end to end
#   tb_matvec_axi               the PS register-map sequence
#   tb_matvec_core              trace-driven, thousands of trace lines
#   tb_gdn_conv_cycles          CH_MAX=3072 cycle accounting
#   tb_b_audit_ser_handshake    serialiser handshake audit over 3 blocks
#   tb_hbm_tg                   HBM traffic generator, long burst program
#   tb_seq_desc_fetch           491-descriptor walk
#   tb_seq_opdec                491-step walk through three units
#   tb_seq_region_lock          491-step plan
#
# Those are exactly the ones that cover the SEAMS between units, which is where
# the cross-subsystem regressions live.  Never conclude "regression is green"
# from a --quick run.
#
# ---------------------------------------------------------------------------
# WHAT IS SKIPPED AND WHY, IN A FULL RUN
# ---------------------------------------------------------------------------
# Nothing is dropped quietly.  Every testbench appears in the output with a
# verdict, and a testbench that cannot be run is printed as SKIPPED with its
# reason.  There are three automatically-detected reasons:
#
#   (a) the testbench declares `library beh` -- it is a post-synthesis
#       netlist-versus-behavioral comparison and needs TWO libraries plus
#       UNISIM/SECUREIP, which is Vivado xsim, not GHDL.  Run those with the
#       matching sim/run_*_cmp.sh after regenerating the netlist.
#   (b) the testbench's closure needs a design unit that only a netlist-side
#       file provides (post_*.vhd, *_net*.vhd, *_ps_wrap*.vhd).  Same reason.
#   (c) the closure names a design unit nothing in rtl/, sim/ or sim/micro/
#       defines.  That is a real hole and it is named in the output.
#
# sim/ is the scope.  The 27 testbenches in tb/ are a separate, older set
# driven by sim/Makefile and are NOT run here; they ARE counted in the coverage
# report, so "no testbench" means no testbench anywhere rather than merely none
# that this script runs.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$REPO/sim"
GHDL="${GHDL:-ghdl}"
STD="--std=08"
RELAX="-frelaxed"

JOBS=2
TIMEOUT=900
QUICK=0
ONLY=""
LIST_ONLY=0
COVERAGE_ONLY=0
KEEP=0

usage() { sed -n '2,150p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)     QUICK=1; shift ;;
    --jobs)      JOBS="$2"; shift 2 ;;
    --jobs=*)    JOBS="${1#*=}"; shift ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --only)      ONLY="$2"; shift 2 ;;
    --only=*)    ONLY="${1#*=}"; shift ;;
    --list)      LIST_ONLY=1; shift ;;
    --coverage)  COVERAGE_ONLY=1; shift ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   usage ;;
    *) echo "regress.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
done

command -v "$GHDL" >/dev/null 2>&1 || { echo "regress.sh: ghdl not found on PATH" >&2; exit 2; }

SCRATCH="${REGRESS_SCRATCH:-$(mktemp -d -t regress.XXXXXX)}"
mkdir -p "$SCRATCH"
if [ "$KEEP" = 0 ]; then trap 'rm -rf "$SCRATCH"' EXIT; else echo "scratch: $SCRATCH"; fi

# --quick's exclusion list.  Kept next to the header block that documents it.
SLOW_TBS="tb_gdn_block tb_gdn_emit_chain tb_gdn_recur_pipe tb_gdn_y_emit
          tb_engine_dump tb_matvec_int4 tb_matvec_axi tb_matvec_core
          tb_gdn_conv_cycles tb_b_audit_ser_handshake tb_hbm_tg
          tb_seq_desc_fetch tb_seq_opdec tb_seq_region_lock"

# ===========================================================================
# 1. PLAN.  Parse every source, resolve each testbench's closure, order it.
#    Emits, per testbench:  name  status  reason  files  top-entity  vectors
# ===========================================================================
PLAN="$SCRATCH/plan.tsv"
COVER="$SCRATCH/coverage.txt"

python3 - "$REPO" "$PLAN" "$COVER" <<'PYEOF'
import re, os, sys, glob

repo, plan_out, cover_out = sys.argv[1], sys.argv[2], sys.argv[3]

# Netlist-side artefacts.  These are post-synthesis outputs (write_vhdl
# -mode funcsim) and the thin wrappers that give them their PS-facing port
# profile.  They are UNISIM/SECUREIP structural netlists: GHDL has no such
# libraries, so anything that needs one is an xsim job, not a GHDL job.
# This is a NAMING CONVENTION rule, deliberately, and it is the only
# hardcoded classification in the plan.  sim/rope_ps_rtl.vhd is the one
# hand-written RTL stand-in for such a wrapper and is correctly not matched.
NETLIST_RE = re.compile(r'^(post_.*|.*_net(_ren)?|.*_ps_wrap\d*|attn_net_wrap|attn_probe_wrap)\.vhd$')

def strip(src):
    """Drop VHDL comments without disturbing string literals or line count."""
    lines = []
    for ln in src.split('\n'):
        out, i, instr = [], 0, False
        while i < len(ln):
            c = ln[i]
            if c == '"':
                instr = not instr
            if not instr and c == '-' and i + 1 < len(ln) and ln[i+1] == '-':
                break
            out.append(c); i += 1
        lines.append(''.join(out))
    return '\n'.join(lines)

def parse(path):
    raw = strip(open(path, errors='replace').read())
    txt = raw.lower()

    entities = re.findall(r'^[ \t]*entity[ \t]+(\w+)[ \t]+is', txt, re.M)
    defines = set(entities)
    defines |= set(re.findall(r'^[ \t]*package[ \t]+(?!body\b)(\w+)[ \t]+is', txt, re.M))

    refs = set()
    refs |= set(re.findall(r'\buse[ \t]+work\.(\w+)', txt))
    refs |= set(re.findall(r'\bentity[ \t]+work\.(\w+)', txt))
    refs |= set(re.findall(r'\bfor[ \t]+[\w,\s]+:[ \t]*\w+[ \t]+use[ \t]+entity[ \t]+work\.(\w+)', txt))
    # Component instantiation:  label : name [generic map|port map].  The name
    # may sit on its own line, so the match crosses the newline.
    refs |= set(re.findall(r'\n[ \t]*\w+[ \t]*:[ \t]*(\w+)[ \t\n]*(?:generic[ \t]+map|port[ \t]+map)', txt))
    # A component declared and bound by default binding still needs its entity.
    refs |= set(re.findall(r'^[ \t]*component[ \t]+(\w+)', txt, re.M))

    for kw in ('process', 'block', 'if', 'for', 'case', 'while', 'null',
               'entity', 'configuration', 'others', 'work', 'generate'):
        refs.discard(kw)
    refs -= defines

    # Data files opened by bare name (no directory part).  "../mem/golden/..."
    # is deliberately excluded: those are committed golden files reached
    # through the per-test workdir's mem symlink, not generated vectors.
    vecs = set()
    for lit in re.findall(r'"([^"\n]+)"', raw):
        if lit.endswith('.txt') and '/' not in lit and ' ' not in lit:
            vecs.add(lit)
    return defines, refs, entities, sorted(vecs)

sources = []
for pat in ('rtl/*.vhd', 'sim/*.vhd', 'sim/micro/*.vhd'):
    sources += sorted(glob.glob(os.path.join(repo, pat)))

files = {}          # relpath -> (defines, refs, entities, vecs)
provider = {}       # design unit -> relpath  (first non-netlist wins)
netlist_provider = {}
for p in sources:
    rel = os.path.relpath(p, repo)
    base = os.path.basename(p)
    files[rel] = parse(p)
    isnet = bool(NETLIST_RE.match(base))
    for name in files[rel][0]:
        if isnet:
            netlist_provider.setdefault(name, rel)
        elif name not in provider:
            provider[name] = rel

PIN = ['rtl/fixed_luts_pkg.vhd', 'rtl/fixed_pkg.vhd', 'rtl/util_pkg.vhd',
       'rtl/model_cfg_pkg.vhd']

def closure_of(relpath):
    """Transitive closure over the non-netlist provider set."""
    got, netonly, missing = set(), set(), set()
    stack = [relpath]
    while stack:
        f = stack.pop()
        if f in got:
            continue
        got.add(f)
        for r in files[f][1]:
            if r in provider:
                stack.append(provider[r])
            elif r in netlist_provider:
                netonly.add(r)
            else:
                missing.add(r)
    return got, netonly, missing

def toposort(closure, last):
    dep = {}
    for f in closure:
        dep[f] = set()
        for r in files[f][1]:
            q = provider.get(r)
            if q and q in closure and q != f:
                dep[f].add(q)
    ordered, done = [], set()
    pending = [p for p in PIN if p in closure] + \
              sorted(f for f in closure if f not in PIN)
    while pending:
        rest, progressed = [], False
        for f in pending:
            if dep[f] <= done:
                ordered.append(f); done.add(f); progressed = True
            else:
                rest.append(f)
        pending = rest
        if not progressed:
            return None, pending
    return [f for f in ordered if f != last] + [last], []

tbs = sorted(os.path.relpath(p, repo)
             for p in glob.glob(os.path.join(repo, 'sim/tb_*.vhd')))

rows = []
covered = {}
for tb in tbs:
    name = os.path.basename(tb)[:-4]
    # (a) two-library netlist compare -- detected, not listed.
    raw = strip(open(os.path.join(repo, tb), errors='replace').read()).lower()
    if re.search(r'^[ \t]*library[ \t]+beh[ \t]*;', raw, re.M):
        rows.append((name, 'SKIP',
                     'declares `library beh`: post-synthesis netlist-vs-behavioral '
                     'compare, needs xsim + UNISIM (see sim/run_*_cmp.sh)',
                     '', '', ''))
        continue

    cl, netonly, missing = closure_of(tb)
    if netonly:
        who = sorted(netonly)
        rows.append((name, 'SKIP',
                     'needs %s, provided only by a post-synthesis netlist file (%s): '
                     'xsim job, not GHDL' % (', '.join(who), netlist_provider[who[0]]),
                     '', '', ''))
        continue
    if missing:
        rows.append((name, 'SKIP',
                     'unresolved design unit(s): %s -- nothing in rtl/, sim/ or '
                     'sim/micro/ defines them' % ', '.join(sorted(missing)),
                     '', '', ''))
        continue

    ordered, stuck = toposort(cl, tb)
    if ordered is None:
        rows.append((name, 'SKIP',
                     'dependency cycle among: %s' % ', '.join(sorted(stuck)),
                     '', '', ''))
        continue

    # The top-level entity is NOT always the file stem: sim/tb_rope_ps.vhd
    # declares `entity tb_rope`.  Prefer an entity named after the file, else
    # the first tb_* entity the file declares, else the first entity.
    ents = files[tb][2]
    top = name if name in ents else next((e for e in ents if e.startswith('tb_')),
                                         ents[0] if ents else name)

    for f in ordered:
        if f.startswith('rtl/'):
            covered.setdefault(f, []).append(name)
    rows.append((name, 'RUN', '', ' '.join(ordered), top, ' '.join(files[tb][3])))

# Tab is IFS whitespace in bash, so an EMPTY field would collapse and shift
# every field after it.  '-' stands in for an empty field.
with open(plan_out, 'w') as fh:
    for r in rows:
        fh.write('\t'.join(x if x else '-' for x in r) + '\n')

# --- coverage: RTL files with no testbench -------------------------------
# The tb/ set is measured the SAME way as sim/ -- by transitive closure, not
# by direct instantiation -- or rtl/layer_ar.vhd would read as uncovered
# merely because tb/tb_engine.vhd reaches it through engine.vhd.
tbdir = {}
for p in sorted(glob.glob(os.path.join(repo, 'tb/tb_*.vhd'))):
    rel = os.path.relpath(p, repo)
    files[rel] = parse(p)
    cl, _, _ = closure_of(rel)
    for f in cl:
        if f.startswith('rtl/'):
            tbdir.setdefault(f, []).append(os.path.basename(p)[:-4])

rtl = sorted(os.path.relpath(p, repo) for p in glob.glob(os.path.join(repo, 'rtl/*.vhd')))
with open(cover_out, 'w') as fh:
    uncov = [f for f in rtl if not covered.get(f) and not tbdir.get(f)]
    fh.write('TOTAL_RTL %d\n' % len(rtl))
    fh.write('UNCOVERED %d\n' % len(uncov))
    for f in uncov:
        fh.write('NOTB %s\n' % f)
    for f in rtl:
        if not covered.get(f) and tbdir.get(f):
            fh.write('TBDIRONLY %s %s\n' % (f, ','.join(sorted(set(tbdir[f])))))
PYEOF

[ -s "$PLAN" ] || { echo "regress.sh: plan generation failed" >&2; exit 2; }

# ===========================================================================
# 2. EXTRAS.  Per-testbench generics, stop-time, vector generation and success
#    marker, lifted from the existing scripts rather than reinvented.  Every
#    row cites its source.  A testbench not named here runs on its own generic
#    defaults, which is the common case: most of these testbenches declare
#    sensible defaults and a committed vector file next to them in sim/.
# ===========================================================================
tb_args() {   # extra `ghdl -r` arguments for $1
  case "$1" in
    # sim/run_gdn_emit_chain.sh.  OVERLAP=true is how the chain actually runs
    # and is the mode that catches the w_mant hazard; --stop-time is a backstop
    # only, the testbench drops `running` itself.
    tb_gdn_emit_chain)   echo "-gOVERLAP=true -gCOL_GAP=4 -gSTRICT=false -gSILU_LANES=16 -gRMS_LANES=4 --stop-time=300ms" ;;
    # sim/run_gdn_block.sh reference point: every producer maximally ahead.
    tb_gdn_block)        echo "-gOUTFILE=gdn_block_out.txt --stop-time=200ms" ;;
    # sim/run_matvec.sh stage 5/6/7 baselines.  --stop-delta is raised because
    # the trace loader spends one delta per line, which trips ghdl's 5000
    # default and looks exactly like a zero-delay loop.  It is not one.
    tb_matvec_core)      echo "-gTRACE=../tr.txt -gRI=4 -gSTALL=0 --stop-time=50ms --stop-delta=1000000" ;;
    tb_matvec_int4)      echo "-gTRACE=../tr.txt -gRI=4 -gSTALL=3 --stop-time=30ms --stop-delta=1000000" ;;
    tb_matvec_axi)       echo "-gTRACE=../tr.txt -gRI=4 -gSTALL=3 --stop-time=50ms --stop-delta=1000000" ;;
    # sim/run_matvec.sh stages 4 and 4b, first row of each sweep.
    tb_act_mem)          echo "-gELEMS=544 -gBLK=32 -gLANES=4 --stop-time=500ms" ;;
    tb_axi_rd_port)      echo "-gMAXOUT=2 -gDEPTH=64 -gSTALL=3 --stop-time=200ms" ;;
    # sim/run_seq_*.sh named configuration: the one the real system runs
    # closest to (memory fast, units slow, so the prefetch gets far ahead).
    tb_seq_desc_fetch)   echo "-gURAM_LAT=1 -gJOB_LAT=120 -gLAT_SKEW=11 -gSTRICT=true --stop-time=400ms" ;;
    tb_seq_opdec)        echo "-gURAM_LAT=1 -gJOB_LAT=40 -gLAT_SKEW=7 -gSTRICT=true --stop-time=400ms" ;;
    tb_seq_region_lock)  echo "-gWR_N=6 -gWR_GAP=0 -gJOB_LAT=12 -gSTRICT=true --stop-time=400ms" ;;
    # sim/run_seq_vec_res.sh: ACK_LAG=0 is NOT the weak case, see that header.
    tb_seq_vec_res)      echo "-gNCASE=64 -gACK_LAG=0 --stop-time=900ms" ;;
    *)                   echo "--stop-time=900ms" ;;
  esac
}

# Generator arguments for vector files that are not committed.  Lifted from
# the mutate_*.sh / run_*.sh that owns each one, and chosen to match the
# testbench's own generic defaults -- the vector file carries a shape header
# that the testbench asserts against, so a mismatch is loud, not silent.
# A vector with no row here falls back to the generator's own defaults.
tb_vector_args() {   # <vector-file-name> -> generator argv after the filename
  case "$1" in
    attn_emit_vec.txt)      echo "40 2 48" ;;      # sim/mutate_attn_emit.sh
    attn_gate_vec.txt)      echo "35 64" ;;        # sim/mutate_attn_gate.sh
    attn_recip_vec.txt)     echo "24 12" ;;        # sim/mutate_attn_recip.sh
    attn_softmax_vec.txt)   echo "44 24" ;;        # sim/mutate_attn_softmax.sh
    attn_twiddle_vec.txt)   echo "24 32" ;;        # sim/mutate_attn_twiddle.sh
    seq_vec_res_vec.txt)    echo "64 12345" ;;     # sim/run_seq_vec_res.sh
    gdn_emit_chain_vec.txt) echo "3 24 128" ;;     # sim/run_gdn_emit_chain.sh
    *) : ;;
  esac
}

# Success markers for testbenches whose pass is stated as a counter rather
# than as the word PASS.  Where a run_*.sh already greps for a phrase to
# decide OK, that same phrase is used here, so the two agree by construction.
tb_pass_marker() {
  case "$1" in
    tb_axi_rd_port)  echo '0 bad beats' ;;                                   # sim/run_matvec.sh 4b
    tb_hbm_tg)       echo 'recovers a known bandwidth at every port count' ;;
    tb_l2norm_rs)    echo 'within tolerance of x/\|\|x\|\| on every case' ;;
    tb_rope_pair)    echo "is exactly ADJACENT's rotation" ;;
    tb_exp_cone)     echo 'VALUES AGREE' ;;
    # The audit bench asserts at severity FAILURE (see its line 203 note) but
    # states its result as three counters.  All three must be zero/complete.
    tb_b_audit_ser_handshake)
      echo 'more than DIM elements: 0.*FEWER than DIM: 0' ;;
    *) : ;;
  esac
}

# Failure-shaped lines that a testbench PROVOKES ON PURPOSE as a negative
# control.  These are filtered out before the failure check, per testbench, by
# exact phrase, with the reason.  Deliberately NOT generic: a blanket "ignore
# assertion errors" would defeat clause 6 entirely.  A testbench that ends by
# proving its DUT's own guard fires is a good testbench, and it must still be
# able to report PASS.
tb_expected_noise() {
  case "$1" in
    # sim/tb_attn_recip.vhd line 39: "nothing in the main loop exercises the
    # s = 0 trap", so the bench drives s = 0 deliberately at the end, and its
    # own PASS line says "the s = 0 trap fires and terminates".  The RTL guard
    # at rtl/attn_recip.vhd:282 is severity ERROR, so ghdl prints an assertion
    # error and still exits 0.
    tb_attn_recip) echo 'attn_recip: s = 0 offered' ;;
    *) : ;;
  esac
}

# Testbenches that are genuinely NOT self-checking.  Each still runs -- a
# crash, an assertion or a hang is still caught -- but a clean exit is not
# evidence of correctness, so they are reported as NOCHECK rather than being
# counted as passes.  This list is short and every entry states why.
tb_nocheck_reason() {
  case "$1" in
    tb_attn_beh)        echo 'observation only: prints per-position xb_exp then BEH_DONE. It is the behavioral half of the xsim netlist compare (sim/run_attn_cmp.sh), not a self-checking bench' ;;
    tb_swchain_beh)     echo 'observation only: prints one o_exp/checksum line. Its header says "GHDL-only sanity bench"; the real check is tb_swchain_cmp under xsim' ;;
    tb_rms_sweep)       echo 'observation only: sweeps xe and prints oe/o0, then SWEEP_DONE. Has no pass criterion; it exists to compare against a recorded hardware reading' ;;
    tb_gdn_conv_cycles) echo 'measurement only: emits a CSV cycle table (CYC,...) and "done". There is no expected value to check it against' ;;
    *) : ;;
  esac
}

# ===========================================================================
# 3. VERDICT.  See point 6 of the header.
# ===========================================================================
# A failure marker anywhere wins over a success marker anywhere.
FAIL_RE='\(assertion (error|failure)\)|\(report (error|failure)\)|:error:|MISMATCH|\bFAIL\b|FAILED|cannot open|error: |simulation failed|DIVERGES|IS NOT|IS WRONG|OUT OF TOLERANCE'
# A success marker must be present or the run is NOVERDICT, never PASS.
# A bare "OK" is deliberately NOT a marker: it is too easy to hit in prose.
PASS_RE='\bPASS\b|\bALL OK\b|all green|0 mismatches|no mismatch|matches ref|bit-exact|bit-identical|within tolerance'

run_one() {   # run_one <tbname> <top-entity> <vectors-csv> <files...>
  local tb="$1" top="$2" vecs="$3"; shift 3
  [ "$vecs" = "-" ] && vecs=""
  local dir="$SCRATCH/$tb" log="$SCRATCH/$tb/log"
  local run="$dir/run" work="$dir/work"
  mkdir -p "$run" "$work"
  ln -sfn "$REPO/mem" "$dir/mem"

  # Everything a testbench might open by bare name.  Committed vectors and
  # golden fixtures live in sim/; symlinking keeps them read-only in practice
  # and means nothing is ever written back into the repo.
  local f
  for f in "$SIM"/*.txt "$SIM"/*.dat "$SIM"/*.csv "$SIM"/*.mem "$SIM"/*.bin; do
    [ -e "$f" ] && ln -sfn "$f" "$run/$(basename "$f")"
  done
  # tb_matvec_* address their trace one level up, as ../tr.txt.
  for f in "$SIM"/tr.txt "$SIM"/arith_vectors.txt; do
    [ -e "$f" ] && ln -sfn "$f" "$dir/$(basename "$f")"
  done

  # NOTE: a subshell, so that an `exit` on a build failure inside it cannot
  # skip the judging code below.  An earlier revision used a brace group and
  # six tests silently produced no result at all.
  (
    echo "### $tb  (top entity: $top)"
    # --- vectors -------------------------------------------------------
    local v stem gen args
    for v in $vecs; do
      stem="${v%.txt}"
      gen="$REPO/ref/$stem.c"
      args="$(tb_vector_args "$v")"
      if [ ! -r "$gen" ]; then
        # No generator.  If sim/ committed one, the symlink above already
        # provides it; otherwise the run will fail loudly on "cannot open".
        continue
      fi
      if [ -e "$SIM/$v" ] && [ -z "$args" ]; then
        continue          # committed, and no curated shape to re-derive
      fi
      if ! cc -O2 -w -I "$REPO/ref" -o "$dir/gen_$stem" "$gen" -lm 2>&1; then
        echo "VECTORGEN_BUILD_FAILED $gen"; exit 90
      fi
      rm -f "$run/$v"
      # shellcheck disable=SC2086
      if ! ( cd "$run" && "$dir/gen_$stem" "$v" $args ) >/dev/null 2>&1; then
        echo "VECTORGEN_RUN_FAILED $gen"; exit 90
      fi
    done

    # --- analysis ------------------------------------------------------
    for f in "$@"; do
      if ! "$GHDL" -a $STD $RELAX --workdir="$work" "$REPO/$f" 2>&1; then
        echo "ANALYSIS_FAILED $f"; exit 91
      fi
    done

    # --- run.  mcode: -e emits nothing, so -r is called directly. -------
    # shellcheck disable=SC2046,SC2086
    ( cd "$run" && timeout -k 5 "$TIMEOUT" \
        "$GHDL" -r $STD $RELAX --workdir="$work" "$top" \
        $(tb_args "$tb") --max-stack-alloc=0 2>&1 )
    echo "GHDL_EXIT=$?"
  ) > "$log" 2>&1

  # ---- judge --------------------------------------------------------
  local rc body marker nocheck
  rc=$(grep -oE '^GHDL_EXIT=[0-9]+' "$log" | tail -1 | cut -d= -f2)
  body=$(grep -avE '^(### |GHDL_EXIT=)' "$log")

  verdict() { printf '%s\t%s\t%s\n' "$tb" "$1" "$2" > "$SCRATCH/res.$tb"; }

  if grep -q '^VECTORGEN' "$log"; then
    verdict ERROR "reference vector generator failed: $(grep -m1 '^VECTORGEN' "$log")"; return
  fi
  if grep -q '^ANALYSIS_FAILED' "$log"; then
    verdict ERROR "ghdl -a failed on $(grep -m1 '^ANALYSIS_FAILED' "$log" | cut -d' ' -f2): $(printf '%s' "$body" | grep -aiE 'error' | head -1 | cut -c1-120)"; return
  fi
  [ -n "${rc:-}" ] || rc=1
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    verdict TIMEOUT "no result within ${TIMEOUT}s -- unguarded clock or deadlock, NOT the same thing as a failure"; return
  fi
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    verdict FAIL "produced NO output at all (exit $rc)"; return
  fi
  local noise; noise="$(tb_expected_noise "$tb")"
  if [ -n "$noise" ]; then
    body="$(printf '%s' "$body" | grep -avE "$noise")"
  fi
  if [ "$rc" != "0" ]; then
    verdict FAIL "exit $rc: $(printf '%s' "$body" | grep -aE "$FAIL_RE" | head -1 | cut -c1-160)"; return
  fi
  if printf '%s' "$body" | grep -aqE "$FAIL_RE"; then
    verdict FAIL "$(printf '%s' "$body" | grep -aE "$FAIL_RE" | head -1 | cut -c1-160)"; return
  fi

  marker="$(tb_pass_marker "$tb")"
  if [ -n "$marker" ]; then
    if printf '%s' "$body" | grep -aqE "$marker"; then
      verdict PASS "$(printf '%s' "$body" | grep -aE "$marker" | head -1 | cut -c1-140)"; return
    fi
    verdict NOVERDICT "ran clean but its declared success marker ('$marker') never appeared"; return
  fi

  nocheck="$(tb_nocheck_reason "$tb")"
  if [ -n "$nocheck" ]; then
    verdict NOCHECK "$nocheck"; return
  fi

  if printf '%s' "$body" | grep -aqiE "$PASS_RE"; then
    verdict PASS "$(printf '%s' "$body" | grep -aiE "$PASS_RE" | head -1 | cut -c1-140)"; return
  fi
  verdict NOVERDICT "exit 0 and no failure marker, but NO success marker either -- that is not evidence of a pass"
}

# ===========================================================================
# 4. DRIVE
# ===========================================================================
selected=()
skipped_names=(); skipped_reasons=()
while IFS=$'\t' read -r name status reason flist top vecs; do
  [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]] && continue
  if [ "$status" = "SKIP" ]; then
    skipped_names+=("$name"); skipped_reasons+=("$reason"); continue
  fi
  if [ "$QUICK" = 1 ] && [[ " $SLOW_TBS " == *" $name "* ]]; then
    skipped_names+=("$name")
    skipped_reasons+=("--quick: slow seam/top-level test, deliberately excluded -- run without --quick")
    continue
  fi
  # Keep the '-' placeholder: with IFS=tab an EMPTY field collapses and every
  # field after it shifts, which is how the analysis file list once ended up in
  # the vectors slot and every test reported "cannot find entity".
  selected+=("$name"$'\t'"$top"$'\t'"$vecs"$'\t'"$flist")
done < "$PLAN"

if [ "$LIST_ONLY" = 1 ]; then
  echo "== plan =="
  for e in "${selected[@]}"; do
    IFS=$'\t' read -r n t v fl <<< "$e"
    printf 'RUN  %-28s entity=%-24s %2d files  vectors=%s\n' \
           "$n" "$t" "$(echo "$fl" | wc -w)" "$([ "$v" = "-" ] && echo none || echo "$v")"
  done
  for i in "${!skipped_names[@]}"; do
    printf 'SKIP %-28s %s\n' "${skipped_names[$i]}" "${skipped_reasons[$i]}"
  done
  exit 0
fi

if [ "$COVERAGE_ONLY" = 0 ]; then
  echo "================================================================================"
  echo " llama.vhdl regression -- $( [ "$QUICK" = 1 ] && echo 'QUICK subset (NOT coverage)' || echo 'FULL run' ), ${JOBS} job(s), ${TIMEOUT}s per test"
  echo " $(date '+%Y-%m-%d %H:%M:%S')   ghdl: $($GHDL --version | head -1)"
  echo "================================================================================"

  for e in "${selected[@]}"; do
    IFS=$'\t' read -r n t v fl <<< "$e"
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.4; done
    # shellcheck disable=SC2086
    run_one "$n" "$t" "$v" $fl &
  done
  wait

  npass=0; nfail=0; ntime=0; nerr=0; nnov=0; nnoc=0
  failed_list=()
  echo
  for e in "${selected[@]}"; do
    n="${e%%$'\t'*}"
    if [ -r "$SCRATCH/res.$n" ]; then
      IFS=$'\t' read -r rn rv rd < "$SCRATCH/res.$n"
    else
      rv="FAIL"; rd="the runner produced no result file for this test"
    fi
    printf '%-10s %-30s %s\n' "$rv" "$n" "$rd"
    case "$rv" in
      PASS)      npass=$((npass+1)) ;;
      NOCHECK)   nnoc=$((nnoc+1)) ;;
      TIMEOUT)   ntime=$((ntime+1)); failed_list+=("$n (timeout)") ;;
      ERROR)     nerr=$((nerr+1));  failed_list+=("$n (build error)") ;;
      NOVERDICT) nnov=$((nnov+1));  failed_list+=("$n (no verdict)") ;;
      *)         nfail=$((nfail+1)); failed_list+=("$n") ;;
    esac
  done

  echo
  echo "-- SKIPPED (listed, never dropped silently) ------------------------------------"
  if [ "${#skipped_names[@]}" = 0 ]; then
    echo "(none)"
  else
    for i in "${!skipped_names[@]}"; do
      printf 'SKIPPED    %-30s %s\n' "${skipped_names[$i]}" "${skipped_reasons[$i]}"
    done
  fi
fi

# ===========================================================================
# 5. COVERAGE: RTL with no testbench anywhere
# ===========================================================================
echo
echo "-- RTL FILES WITH NO TESTBENCH -------------------------------------------------"
echo "   (transitive closure, checked against BOTH sim/tb_*.vhd and tb/tb_*.vhd)"
awk '/^NOTB /{print "   no testbench   " $2}' "$COVER"
tot=$(awk '/^TOTAL_RTL/{print $2}' "$COVER")
unc=$(awk '/^UNCOVERED/{print $2}' "$COVER")
echo "   $unc of $tot files in rtl/ are reached by no testbench at all."
if grep -q '^TBDIRONLY' "$COVER"; then
  echo
  echo "   reached ONLY by the older tb/ set, which regress.sh does not run:"
  awk '/^TBDIRONLY /{printf "     %-32s %s\n", $2, $3}' "$COVER"
fi

[ "$COVERAGE_ONLY" = 1 ] && exit 0

echo
echo "================================================================================"
printf ' PASS %d   FAIL %d   NOVERDICT %d   TIMEOUT %d   BUILD-ERROR %d   NOCHECK %d   SKIPPED %d\n' \
  "$npass" "$nfail" "$nnov" "$ntime" "$nerr" "$nnoc" "${#skipped_names[@]}"
echo "================================================================================"
if [ "${#failed_list[@]}" -gt 0 ]; then
  echo " NOT GREEN:"
  for f in "${failed_list[@]}"; do echo "   - $f"; done
  echo
  echo " REGRESSION: FAIL"
  exit 1
fi
echo " REGRESSION: PASS"
exit 0
