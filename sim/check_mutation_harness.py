#!/usr/bin/env python3
"""Audit every mutation harness for the one defect a mutation harness cannot
have: an anchor that matched NOTHING reported as a row that SURVIVED.

WHY THIS EXISTS.  A mutation anchor is TEXT, and text drifts under the file it
points into.  When it drifts, the substitution matches zero times -- and in
several of this repository's harnesses the failed substitution yielded the
EMPTY STRING, which every consumer here reads as "no mutated source, use the
repo file".  The PRISTINE design was then built, run, and reported SURVIVED.
A row that never mutated anything is indistinguishable in the output from a
row whose mutation the checks genuinely tolerate, and the direction of the
error is the flattering one: it inflates the measured coverage.

MEASURED 2026-09-20 by TRACK MUTAUDIT, by running the harnesses with an
impossible anchor:

  sim/mutate_attn_block.sh        M1 -> "M1  SURVIVED"
  sim/mutate_attn_score_early.sh  E1 -> "E1_on  SURVIVED"
  sim/mutate_attn_sweep_pipe.sh   P1 -> "P1_on  SURVIVED"
  sim/mutate_normw.sh             M1 -> "bench PASS  R_XN oracle 9/9", byte
                                  for byte the unmutated M0 row
  sim/mutate_a_geom.sh            M1 -> "PASS  (want ANALYSIS or FAIL)"

and, in the other direction, the same rows with their real anchors gave
KILLED / ABORT / 8-of-9 / FAIL.  All five are fixed; this checker is what
stops the shape coming back.

WHAT THIS CHECKER IS, AND WHAT IT IS NOT.  It is a STATIC detector, so it is
a LEAD and not a proof: the only proof that a harness can tell an unapplied
mutation from an inert one is a Z0 self-teeth ROW inside that harness, run.
Its teeth are therefore its own selftest, which requires it to name EXACTLY
the five files above as they stood at commit 56d13e3 and to name NONE on the
tree in front of it.  A detector that has never been shown to discriminate on
the thing it guards is decoration, and this one is shown against seven
MEASURED states -- five positive, and the safe representatives below that
were each demonstrated by running them with an impossible anchor.

Usage:
  python3 sim/check_mutation_harness.py            # audit the tree
  python3 sim/check_mutation_harness.py --selftest # the teeth, then the audit
"""

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(REPO, "sim", "mutation_harness_audit.tsv")

# The commit the five vulnerable harnesses were measured at, before the fix.
# It is the selftest's POSITIVE control and must not be repointed at a tree in
# which they are fixed -- that would turn the selftest into a check that
# passes for the wrong reason.
FIXTURE_COMMIT = "56d13e3"
FIXTURE_VULNERABLE = [
    "sim/mutate_attn_block.sh",
    "sim/mutate_attn_score_early.sh",
    "sim/mutate_attn_sweep_pipe.sh",
]
# The NEGATIVE control.  Each of these was demonstrated SAFE at the same
# commit by running it with an impossible anchor; the detector must not name
# them.  mutate_attn_kv_seam and mutate_llama_top_kv are here because they
# carry the same `echo ""` helper as the positives and are saved only by
# their call sites, which is exactly the discrimination being tested.
FIXTURE_SAFE = [
    "sim/mutate_fk33_seam.sh",
    "sim/mutate_llama_top_smp.sh",
    "sim/mutate_attn_kv_seam.sh",
    "sim/mutate_llama_top_kv.sh",
    "sim/mutate_a_drain_wide.sh",
]
# sim/mutate_swg_wide.sh was demonstrated SAFE the same day by the same probe
# and is deliberately NOT a fixture: it is UNTRACKED at 56d13e3, so `git show`
# cannot reach it and a fixture that cannot be fetched is a selftest row that
# fails for a reason unrelated to the detector.  It is audited in the manifest
# like every other harness.

FUNC_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{\s*$")
ASSIGN_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=\"?\$\((\w+)\s")
CALL_HEAD_RE = re.compile(r"^\s*(?:if\s+|\[\s*-n[^]]*\]\s*&&\s*)?"
                          r"([a-zA-Z_][a-zA-Z0-9_]*)\s")
# EVERY "$VAR" on the line, not the last one.  A first draft used a single
# greedy `.*"\$(\w+)"` and matched only the FINAL argument -- which on
# sim/mutate_attn_block.sh's rows is "$GEN", the oracle source, so the mutdir
# argument "$M1" was never examined and the file came back SAFE against a
# MEASURED vulnerability.  The selftest is what caught that.
VAR_RE = re.compile(r'"\$([A-Za-z_][A-Za-z0-9_]*)"')


def functions(lines):
    """Top-level shell functions as {name: (start, end)} over line indices."""
    out = {}
    i = 0
    while i < len(lines):
        m = FUNC_RE.match(lines[i])
        if m:
            j = i + 1
            while j < len(lines) and lines[j].rstrip() != "}":
                j += 1
            out[m.group(1)] = (i, j)
            i = j
        i += 1
    return out


def body(lines, span):
    return "\n".join(lines[span[0]:span[1] + 1])


def yields_empty_on_anchor_failure(fbody):
    """The helper hands back the EMPTY STRING when the substitution failed."""
    return bool(re.search(r"\$\?\s*-ne\s*0\s*\]?[;)]?\s*(&&\s*\{|then)?\s*"
                          r"(\{\s*)?echo\s+\"\"", fbody))


def has_empty_or_sentinel_guard(fbody):
    """The consumer refuses to run when it was handed nothing."""
    if "__ANCHOR_FAIL__" in fbody:
        return True
    m = re.search(r'\[\s*-z\s+"\$[A-Za-z_][A-Za-z0-9_]*"\s*\]', fbody)
    if not m:
        return False
    tail = fbody[m.start():m.start() + 400]
    return "return" in tail or "exit" in tail


def guarded_call_site(lines, idx, var):
    """The call is skipped when $var is empty.  Three spellings occur here and
    all three are real guards, so all three are recognised:

      same line      `[ -n "$D" ] && row ...`
      enclosing if   `if [ -n "$D" ]; then ... row ... fi`
      early return   `[ -n "$D" ] || { echo "...ANCHOR FAILED"; return; }`
                     earlier in the SAME function body, which is the form
                     sim/mutate_a_drain_wide.sh and sim/mutate_swg_wide.sh use
                     and which a first draft of this detector missed -- it
                     reported a_drain_wide VULNERABLE against a MEASURED SAFE.
    """
    line = lines[idx]
    if re.search(r'\[\s*-n\s+"\$%s"\s*\]\s*(&&|\|\|)' % re.escape(var), line):
        return True
    if re.search(r'\[\s*\$\?\s*-eq\s*0\s*\]\s*&&', line):
        return True
    depth = 0
    for k in range(idx - 1, max(-1, idx - 400), -1):
        s = lines[k].strip()
        if s == "}":          # the top of the enclosing function body
            break
        if re.search(r'\[\s*-n\s+"\$%s"\s*\]\s*\|\|' % re.escape(var), s) \
                and "return" in s:
            return True
        if s == "fi" or s.startswith("fi "):
            depth += 1
        elif s.startswith("if "):
            if depth == 0 and re.search(
                    r'\[\s*-n\s+"\$%s"\s*\]' % re.escape(var), s):
                return True
            if depth:
                depth -= 1
    return False


def audit_text(text):
    """-> (verdict, [notes]).  verdict is VULNERABLE / SAFE / NOT-THIS-SHAPE."""
    lines = text.split("\n")
    fns = functions(lines)
    helpers = {n for n, sp in fns.items()
               if yields_empty_on_anchor_failure(body(lines, sp))}
    if not helpers:
        return "NOT-THIS-SHAPE", ["no helper hands back the empty string on a "
                                  "failed anchor"]
    mutvars = {}
    for i, ln in enumerate(lines):
        m = ASSIGN_RE.match(ln)
        if m and m.group(2) in helpers:
            mutvars[m.group(1)] = i
    bad = []
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("#"):
            continue
        m = CALL_HEAD_RE.match(ln)
        if not m:
            continue
        callee = m.group(1)
        if callee in helpers or callee not in fns:
            continue
        for var in VAR_RE.findall(ln):
            if var not in mutvars or mutvars[var] > i:
                continue
            if has_empty_or_sentinel_guard(body(lines, fns[callee])):
                continue
            if guarded_call_site(lines, i, var):
                continue
            bad.append("line %d: %s is passed \"$%s\" with no empty-mutdir "
                       "guard in %s() and no guard at the call site"
                       % (i + 1, callee, var, callee))
    if bad:
        return "VULNERABLE", bad
    return "SAFE", ["every call site of a mutator result is guarded, or the "
                    "consumer refuses an empty/sentinel mutdir"]


def read_manifest():
    rows = {}
    if not os.path.exists(MANIFEST):
        return None
    for ln in open(MANIFEST):
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#"):
            continue
        f = ln.split("\t")
        if len(f) < 4:
            print("MANIFEST: malformed line: %r" % ln)
            return {}
        rows[f[0]] = f[1:]
    return rows


def git_show(commit, path):
    return subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (commit, path)],
                          capture_output=True, text=True)


def selftest():
    """THE TEETH.  The detector must name every measured positive and no
    measured negative, at the commit they were measured at."""
    fails = 0
    print("--- selftest: the detector against MEASURED states at %s ---"
          % FIXTURE_COMMIT)
    for path, want in ([(p, "VULNERABLE") for p in FIXTURE_VULNERABLE]
                       + [(p, "SAFE") for p in FIXTURE_SAFE]):
        r = git_show(FIXTURE_COMMIT, path)
        if r.returncode != 0:
            print("  %-34s FIXTURE UNREACHABLE at %s -- the selftest cannot "
                  "run, so this checker is unproven" % (path, FIXTURE_COMMIT))
            fails += 1
            continue
        got, notes = audit_text(r.stdout)
        ok = (got == want)
        print("  %-34s want %-12s got %-14s %s"
              % (path, want, got, "OK" if ok else "<== WRONG"))
        if not ok:
            for n in notes[:3]:
                print("        %s" % n)
            fails += 1
    # normw and a_geom are the two shapes this detector CANNOT see, and they
    # are declared here rather than omitted.  normw applies its mutations with
    # inline python whose rc is read by mrow, and a_geom with sed guarded by
    # msub; neither goes through a helper that returns a directory, so
    # audit_text reports NOT-THIS-SHAPE for both, before and after the fix.
    # Their guard is their Z0 row, which the manifest requires and R2 checks.
    for path in ("sim/mutate_normw.sh", "sim/mutate_a_geom.sh"):
        r = git_show(FIXTURE_COMMIT, path)
        if r.returncode == 0:
            got, _ = audit_text(r.stdout)
            print("  %-34s KNOWN BLIND SPOT: reports %s both before and after "
                  "the fix; its guard is its Z0 row" % (path, got))
    print("--- selftest %s ---" % ("PASS" if fails == 0 else "FAIL"))
    return fails


def main():
    rc = 0
    if "--selftest" in sys.argv:
        rc += selftest()

    man = read_manifest()
    if man is None:
        print("FAIL: %s is missing.  Every mutation harness must be audited "
              "for the zero-match-anchor defect and recorded there." % MANIFEST)
        return 1

    here = sorted(f for f in os.listdir(os.path.join(REPO, "sim"))
                  if f.startswith("mutate_") and f.endswith(".sh"))
    here = ["sim/" + f for f in here]

    # R1 -- completeness.  A NEW harness is the way this defect comes back:
    # they are written by copying an existing one, and three of the five that
    # were vulnerable are copies of each other.
    missing = [f for f in here if f not in man]
    stale = [f for f in man if f not in here]
    for f in missing:
        print("FAIL R1: %s is not in sim/mutation_harness_audit.tsv.  Audit it "
              "(run it with an impossible anchor and read the row it prints) "
              "and record the verdict." % f)
        rc += 1
    for f in stale:
        print("FAIL R1: the manifest names %s, which does not exist." % f)
        rc += 1

    # R2 -- a script that CLAIMS a self-teeth row must have one.
    for f in here:
        if f not in man or man[f][0] != "SELFTEETH":
            continue
        txt = open(os.path.join(REPO, f)).read()
        if not re.search(r"^\s*(run_case|row|mrow|v=\$\(mrun)(\s+\$\?)?\s+Z0\w*\b", txt, re.M):
            print("FAIL R2: %s is recorded SELFTEETH but has no Z0 row." % f)
            rc += 1
        if "BADMUT" not in txt:
            print("FAIL R2: %s is recorded SELFTEETH but never prints BADMUT, "
                  "so its Z0 row has nothing distinct to report." % f)
            rc += 1
        if "Z0SEEN" not in txt:
            print("FAIL R2: %s is recorded SELFTEETH but does not check that "
                  "its Z0 row fired.  A self-teeth row whose result nothing "
                  "reads is decoration." % f)
            rc += 1

    # R3 -- the detector itself, over the live tree.
    for f in here:
        verdict, notes = audit_text(open(os.path.join(REPO, f)).read())
        if verdict == "VULNERABLE":
            print("FAIL R3: %s can report a zero-match anchor as a SURVIVED "
                  "row." % f)
            for n in notes:
                print("        %s" % n)
            rc += 1

    print("checked %d harnesses; %d finding(s)" % (len(here), rc))
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
