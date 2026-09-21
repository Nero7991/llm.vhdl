#!/usr/bin/env python3
"""sim/check_elab_rows.py -- TRACK ELABCLASS, 2026-09-20.

THE HALF OF THE DISCRIMINATOR THAT CAN RUN ON EVERY GATE.

`sim/elab_check_run.sh` answers "does this generic value elaborate", and it
needs a Vivado lane, so it cannot be a gate row.  This script answers the
question that made that one necessary and costs milliseconds:

    HAS A BOOLEAN GENERIC ARM APPEARED THAT NOTHING HAS EVER SYNTHESISED AND
    THAT NOBODY HAS DECIDED ABOUT?

It recomputes the census from the RTL every run and fails when a reachable
never-synthesised arm is neither in `elab_check_run.sh`'s row table nor in the
EXEMPT list below with a reason attached.  So adding a lever generic turns the
gate red until someone either schedules an elaboration row for it or writes
down why it does not need one.

WHY THIS IS THE RIGHT SHAPE.  TRACK HDRCOST's `SCORE_HDR_TREE` was released,
documented, benched twenty ways and never once handed to a synthesiser.
Nothing in this repository could notice that, because the thing to notice is an
ABSENCE.  A gate row cannot run Vivado; it can check that the absence has been
acknowledged.

WHAT IT DELIBERATELY DOES NOT DO.  It does not claim an arm is SOUND because it
is listed.  A row in the table is a scheduled measurement, not a result.

  usage: python3 sim/check_elab_rows.py [--repo DIR] [--list]
  exit 0 = every reachable never-synthesised arm is accounted for
  exit 1 = at least one is not
"""
import argparse
import collections
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# EXEMPT: a reachable never-synthesised boolean arm that deliberately has no
# elaboration row, WITH THE REASON.  An entry here is a decision, not a
# silencer, and the reason is what the next reader is owed.
#
# Ranked LOW by TRACK ELABCLASS on 2026-09-20 after READING the code, not after
# counting occurrences: none of these appears in a loop bound or an array bound,
# so none can move a statically folded index, which is the failure mode the
# elaboration rows exist to catch.
EXEMPT = {
    'A_BEHAV':
        'behavioural stand-in for subsystem A; replaces real logic with a stub, '
        'so it elaborates strictly less than the arm the card builds.',
    'B_BEHAV':
        'behavioural stand-in for subsystem B; same argument as A_BEHAV.',
    'DEBUG':
        'rmsnorm debug reporting only; no loop bound, no array bound.',
    'DEBUG_TAPS':
        'engine_shared debug taps; adds ports and assignments, changes no '
        'loop bound and no array bound.',
    'D_NORM':
        'gdn_recur_pipe: appears only in `if D_NORM` inside the recurrence '
        'process. The six static-index sites in that file are the redk/reda/redo '
        'reduction trees, whose bound is LOG2L from LANES, i.e. B_RECUR_LANES -- '
        'and that generic HAS been synthesised at 4 and at 16.',
    'EG0_ED': 'gdn_recur_pipe: same argument as D_NORM.',
    'TK0_ED': 'gdn_recur_pipe: same argument as D_NORM.',
    'NEOX':
        'rope: changes pair_a/pair_b, which are functions of the RUN-TIME '
        'variable `idx`, so the index is a mux and not a folded constant.',
    'PROBES':
        'attention_ml probe ports; the false arm elaborates strictly less.',
    'REL_NAIVE':
        'seq_opdec: selects a decode rule, no loop bound, no array bound.',
    'STRICT_PROTO':
        'seq_desc_fetch: adds protocol asserts, no loop bound, no array bound.',
}

# Arms whose non-default value IS bound by a `sim/ooc_*.tcl` or `*_run.sh`
# harness, read out of a literal in the script text.  Kept as an explicit list
# rather than re-derived, because several of those scripts take their top and
# their generics from argv or env and are therefore NOT evidence about any
# shape; see docs/debugging/2026-09-20_the-defect-only-a-synthesiser-sees.md
# section 6.3.
OOC_COVERED = {
    'FAST_POP':
        'bound true in sim/ooc_aidle.tcl, sim/ooc_aidle_run.sh and '
        'sim/ooc_levercost_run.sh, and false in the same scripts.',
    'CONST_EN':
        'bound true in sim/ooc_bmover.tcl, sim/ooc_bmover_run.sh and '
        'sim/ooc_bnarrow_run.sh.',
    'USE_XEXP_PORT':
        'bound true in sim/ooc_levercost_run.sh and sim/ooc_cbooc_run.sh.',
}


def strip_comment(line):
    i = line.find('--')
    return line[:i] if i >= 0 else line


GEN_OPEN = re.compile(r'^\s*generic\s*\(', re.I)
BOOL_DECL = re.compile(r'^\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*boolean\b'
                       r'\s*(?::=\s*(true|false))?', re.I)
ENTITY = re.compile(r'^\s*entity\s+(\w+)\s+is\b', re.I)
PORT_OPEN = re.compile(r'^\s*port\s*\(', re.I)
MAPVAL = re.compile(r'(\w+)\s*=>\s*([A-Za-z_]\w*)')
INST = re.compile(r'entity\s+work\.(\w+)\b', re.I)


def scan_rtl(rtl_dirs):
    """-> (bool_decls, literals, instantiated)

    bool_decls  : NAME -> {entity: default}
    literals    : NAME -> set of 'true'/'false' seen in any generic map
    instantiated: set of entity names instantiated anywhere
    """
    bool_decls = collections.defaultdict(dict)
    literals = collections.defaultdict(set)
    instantiated = set()
    for d in rtl_dirs:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith('.vhd'):
                continue
            ent = None
            in_gen = False
            depth = 0
            for raw in open(os.path.join(d, fn), errors='replace'):
                line = strip_comment(raw)
                m = ENTITY.match(line)
                if m:
                    ent = m.group(1)
                    in_gen = False
                if ent and not in_gen and GEN_OPEN.match(line):
                    in_gen = True
                    depth = line.count('(') - line.count(')')
                    continue
                if in_gen:
                    depth += line.count('(') - line.count(')')
                    mm = BOOL_DECL.match(line)
                    if mm:
                        for nm in mm.group(1).split(','):
                            nm = nm.strip()
                            if nm:
                                bool_decls[nm.upper()][ent] = (mm.group(2) or '').lower()
                    if depth <= 0 or PORT_OPEN.match(line):
                        in_gen = False
                for mm in INST.finditer(line):
                    instantiated.add(mm.group(1).lower())
                for mm in MAPVAL.finditer(line):
                    v = mm.group(2).lower()
                    if v in ('true', 'false'):
                        literals[mm.group(1).upper()].add(v)
    return bool_decls, literals, instantiated


ROWGEN = re.compile(r'^\s*\w+\)\s*echo\s+"(.*)";;\s*$')


def rows_covered(path):
    """Generic names that appear in any row of elab_check_run.sh's row_gen()."""
    names = set()
    inside = False
    for raw in open(path, errors='replace'):
        if raw.startswith('row_gen()'):
            inside = True
            continue
        if inside and raw.startswith('}'):
            break
        if inside:
            m = ROWGEN.match(raw)
            if m:
                for tok in m.group(1).split():
                    if '=' in tok:
                        names.add(tok.split('=', 1)[0].lstrip('$').upper())
    # the shell variables the rows expand ($DCARD, $CGEN, $AGEN, ...) hold the
    # rest of the bindings; read them too, from their own assignments.
    for raw in open(path, errors='replace'):
        m = re.match(r'^(?:DCARD|CGEN|AGEN)="(?:\$\w+\s*)?(.*)"\s*$', raw)
        if m:
            for tok in m.group(1).split():
                if '=' in tok:
                    names.add(tok.split('=', 1)[0].lstrip('$').upper())
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=os.path.join(os.path.dirname(
        os.path.abspath(__file__)), '..'))
    ap.add_argument('--list', action='store_true',
                    help='print the whole census, not only the findings')
    a = ap.parse_args()
    repo = os.path.abspath(a.repo)

    bool_decls, literals, instantiated = scan_rtl(
        [os.path.join(repo, 'rtl'), os.path.join(repo, 'hw', 'fk33', 'rtl')])
    runner = os.path.join(repo, 'sim', 'elab_check_run.sh')
    if not os.path.isfile(runner):
        print('ELABROWS FAIL: %s is missing; the elaboration table is the '
              'other half of this check' % runner)
        return 1
    covered = rows_covered(runner)

    findings = []
    census = []
    for nm in sorted(bool_decls):
        ents = bool_decls[nm]
        defaults = set(v for v in ents.values() if v)
        seen = set(literals.get(nm, ())) | defaults
        missing = sorted({'true', 'false'} - seen)
        # An arm on an entity nothing instantiates cannot be built at all.
        reach = [e for e in ents if e and e.lower() in instantiated]
        status = 'both-arms-seen'
        if missing:
            if not reach:
                status = 'unreachable-entity'
            elif nm in OOC_COVERED:
                status = 'ooc-covered'
            elif nm in covered:
                status = 'elab-row'
            elif nm in EXEMPT:
                status = 'exempt'
            else:
                status = 'UNACCOUNTED'
                findings.append((nm, missing, sorted(ents)))
        census.append((nm, ','.join(missing) or '-', status, ','.join(sorted(ents))))

    if a.list:
        print('%-22s %-12s %-20s %s' % ('generic', 'arm-unseen', 'status', 'entities'))
        for row in census:
            print('%-22s %-12s %-20s %s' % row)
        print()

    if findings:
        print('ELABROWS: %d boolean arm(s) that no synthesiser has been given '
              'and that nothing has decided about:' % len(findings))
        for nm, missing, ents in findings:
            print('  %-22s arm(s) never synthesised: %-12s on %s'
                  % (nm, ','.join(missing), ','.join(ents)))
        print('Add a row to sim/elab_check_run.sh\'s row_gen(), or an EXEMPT '
              'entry WITH A REASON in sim/check_elab_rows.py.')
        return 1

    n = sum(1 for r in census if r[1] != '-')
    print('ELABROWS PASS: %d boolean generic names, %d with an arm no '
          'synthesiser has been given, all accounted for '
          '(%d elaboration rows, %d OOC-covered, %d exempt, %d on entities '
          'nothing instantiates).'
          % (len(census), n,
             sum(1 for r in census if r[2] == 'elab-row'),
             sum(1 for r in census if r[2] == 'ooc-covered'),
             sum(1 for r in census if r[2] == 'exempt'),
             sum(1 for r in census if r[2] == 'unreachable-entity')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
