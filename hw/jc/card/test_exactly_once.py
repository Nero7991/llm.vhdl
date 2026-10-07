"""hw/jc/card/test_exactly_once.py -- Task 10 fix round 2 (batched with Task 9).

CRITICAL regression test for the double-execution bug in run_ooc27.sh and
run_card.sh: `run()` used to execute "$@" in non-dry mode, AND each step's own
companion `if [ "$DRY_RUN" != 1 ]` block executed the SAME command again. A
real run therefore: (1) `git apply`d the levers patch twice (the second
fails); (2) ran a generator once with NO `cd`, in the CALLER's cwd (which,
from the repo root, would overwrite the LIVE repo's committed
hw/fk33/rtl/fk33_card.vhd / hw/jc/card/jc_card_bd.tcl etc. with the 27B
regeneration), and once more, correctly, in the companion block; and
(3) launched Vivado twice under one unit name.

This is a NON-dry-run test: it actually executes both scripts (minus the
--dry-run flag) end to end, with `git`, `python3`, `vivado`, `systemd-run`
and `sha256sum` replaced by stubs placed first on PATH, and the real, slow,
destructive `run_capped.sh` replaced via the `RUN_CAPPED` env override both
scripts now honour (default unchanged: the real script).

Safety, by construction, independent of whether the script under test is the
buggy one or the fixed one:
  - `git` and `sha256sum` are thin logging shims that exec the REAL binary --
    safe, because every git/sha256sum invocation here only ever touches
    <root>/src (a fresh `git archive HEAD` extraction, not a git repository)
    or reads files read-only.
  - `python3` is a PURE stub (never execs a real interpreter) that only ever
    writes its fake generator output when invoked with a cwd *under
    <root>/src* (checked via a prefix test against $GEN_EXPECT_PREFIX, an
    env var this test sets). A wrong-cwd invocation -- the exact failure
    mode of the bug -- is logged (so the assertions below catch it) but
    writes NOTHING, so even running this test against the pre-fix scripts
    can never actually corrupt the live repo.
  - `vivado` is a pure stub: it never synthesizes anything, it just writes
    the nonce + DONE sentinel lines the orchestration script's own gate
    reads back from the log.

fix round 3 additions:
  - `RUN_CAPPED`'s override guard (both scripts refuse a non-default value
    unless `JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE=1` is ALSO set -- a stray
    inherited `export RUN_CAPPED=...` must not silently launch the real
    card build with no memory cap and no swap guard) has its own tests,
    which deliberately do NOT set that flag to prove the refusal fires.
  - A MUTANT test proves the "live repo unchanged" / "generator cwd under
    $SRC" oracles actually have teeth: the real RED (above) never reaches
    the generator stage (the pre-fix scripts die at the second `git apply`
    first), and even if it did, this file's own protective python3 stub
    refuses to write outside `$GEN_EXPECT_PREFIX`, so neither oracle is
    ever forced to catch a real corruption in the RED/GREEN tests above.
    The mutant test runs a hand-written fragment (never run_ooc27.sh or
    run_card.sh) that skips the git step and uses a PERMISSIVE python3
    stub that writes wherever its cwd is, against a throwaway `git clone`
    of this repo (never the live tree) -- and shows both oracles correctly
    flag it.
  - The former `test_*_real_run_writes_nothing_outside_root` tests were
    deleted: they asserted the exact same `before == after` the
    exactly-once tests already assert over the same global REPO, so they
    could not fail differently and had no independent content. The mutant
    test above is what actually exercises that guarantee's teeth.

    python3 -m pytest hw/jc/card/test_exactly_once.py -q
"""
import os
import shutil
import stat
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
RUN_OOC27 = os.path.join(HERE, "run_ooc27.sh")
RUN_CARD = os.path.join(HERE, "run_card.sh")
LIVE_FK33_CARD = os.path.join(REPO, "hw", "fk33", "rtl", "fk33_card.vhd")

REAL_GIT = shutil.which("git")
REAL_SHA256SUM = shutil.which("sha256sum")
assert REAL_GIT and REAL_SHA256SUM, "need a real git and sha256sum on PATH to build the shims"


def _write_exec(path, body):
    with open(path, "w") as f:
        f.write(body)
    st = os.stat(path)
    os.chmod(path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


_SHIM_GIT = """#!/usr/bin/env bash
{{
  printf 'git'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
}} >> "$STUB_LOG"
exec "{real_git}" "$@"
"""

_SHIM_SHA256SUM = """#!/usr/bin/env bash
{{
  printf 'sha256sum'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
}} >> "$STUB_LOG"
exec "{real_sha256sum}" "$@"
"""

_STUB_SYSTEMD_RUN = """#!/usr/bin/env bash
{
  printf 'systemd-run'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
} >> "$STUB_LOG"
exit 0
"""

# Pure stub, never execs a real interpreter. Only ever WRITES fake generator
# output when $PWD is under $GEN_EXPECT_PREFIX -- a wrong-cwd call (the bug)
# is logged but produces no file, so it can never touch anything real.
_STUB_PYTHON3 = """#!/usr/bin/env bash
{
  printf 'python3'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
} >> "$STUB_LOG"

under_prefix() {
  case "$1" in "$GEN_EXPECT_PREFIX"*) return 0 ;; *) return 1 ;; esac
}

script="$1"
case "$script" in
  *gen_fk33_card.py)
    if under_prefix "$PWD"; then
      mkdir -p "$PWD/hw/fk33/rtl"
      printf -- '-- stub fk33_card.vhd (test_exactly_once.py)\\nentity fk33_card_stub is end entity;\\n' \\
        > "$PWD/hw/fk33/rtl/fk33_card.vhd"
      echo "wrote hw/fk33/rtl/fk33_card.vhd (stub)"
    fi
    exit 0
    ;;
  *gen_jc_card.py)
    if under_prefix "$PWD"; then
      mkdir -p "$PWD/hw/jc/card" "$PWD/hw/fk33/rtl"
      printf -- '-- stub jc_card_bd.tcl (test_exactly_once.py)\\n' > "$PWD/hw/jc/card/jc_card_bd.tcl"
      printf -- '# stub jc_card.xdc (test_exactly_once.py)\\n'     > "$PWD/hw/jc/card/jc_card.xdc"
      printf -- '-- stub jc_card_top.vhd (test_exactly_once.py)\\n' > "$PWD/hw/jc/card/jc_card_top.vhd"
      [ -s "$PWD/hw/fk33/rtl/fk33_card.vhd" ] || \\
        printf -- '-- stub fk33_card.vhd (test_exactly_once.py)\\n' > "$PWD/hw/fk33/rtl/fk33_card.vhd"
      echo "wrote hw/jc/card/jc_card_bd.tcl hw/jc/card/jc_card.xdc hw/jc/card/jc_card_top.vhd (stub)"
    fi
    exit 0
    ;;
  *gen_ooc27_top.py)
    target="$2"
    if [ -n "$target" ] && under_prefix "$target"; then
      mkdir -p "$target/hw/jc/card"
      printf -- '-- stub jc_ooc27_top.vhd (test_exactly_once.py)\\n' > "$target/hw/jc/card/jc_ooc27_top.vhd"
      echo "GENOOC27_WROTE $target/hw/jc/card/jc_ooc27_top.vhd (stub)"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""

# Pure stub: never synthesizes anything. Writes the nonce + DONE sentinel
# lines both scripts' gates read back from the log Vivado was given via -log.
_STUB_VIVADO = """#!/usr/bin/env bash
{
  printf 'vivado'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
} >> "$STUB_LOG"

logfile=""
nonce=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-log" ]; then logfile="$a"; fi
  if [ "$prev" = "-nonce" ]; then nonce="$a"; fi
  prev="$a"
done
if [ -n "$logfile" ]; then
  {
    echo "JCOOC27_NONCE $nonce"
    echo "JCCARD_NONCE $nonce"
    echo "stub vivado (test_exactly_once.py): pretend synth/place/route ok"
    echo "JCOOC27_DONE"
    echo "JCCARD_DONE"
  } > "$logfile"
fi
exit 0
"""

# Not on PATH: given to the scripts under test via the RUN_CAPPED env
# override. Logs its own call, then drops its own four positional args
# (unit, mem_high, swap_kill_bytes, root) and execs the rest -- which
# resolves "vivado" through the stub bin dir prepended to PATH.
_STUB_RUN_CAPPED = """#!/usr/bin/env bash
{
  printf 'run_capped'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
} >> "$STUB_LOG"
shift 4
exec "$@"
"""

# fix round 3, item 2: a MUTANT python3, unlike the protective _STUB_PYTHON3
# above. It WRITES WHEREVER ITS CWD IS, with no $GEN_EXPECT_PREFIX guard --
# simulating what the real (unstubbed) generator actually does. Used only
# against a throwaway `git clone`, by test_oracle_catches_a_generator_that_
# actually_corrupts_the_wrong_tree below -- never the live tree.
_STUB_PYTHON3_PERMISSIVE = """#!/usr/bin/env bash
{
  printf 'python3'
  printf '\\t%s' "$@"
  printf '\\tCWD=%s\\n' "$PWD"
} >> "$STUB_LOG"
script="$1"
case "$script" in
  *gen_fk33_card.py)
    mkdir -p "$PWD/hw/fk33/rtl"
    printf -- '-- MUTANT-CORRUPTED fk33_card.vhd (test_exactly_once.py)\\n' \\
      > "$PWD/hw/fk33/rtl/fk33_card.vhd"
    echo "wrote hw/fk33/rtl/fk33_card.vhd (MUTANT, unconditional)"
    ;;
esac
exit 0
"""


def _build_stub_env(root, stub_dir, log_path):
    os.makedirs(stub_dir, exist_ok=True)
    _write_exec(os.path.join(stub_dir, "git"), _SHIM_GIT.format(real_git=REAL_GIT))
    _write_exec(os.path.join(stub_dir, "sha256sum"),
                _SHIM_SHA256SUM.format(real_sha256sum=REAL_SHA256SUM))
    _write_exec(os.path.join(stub_dir, "systemd-run"), _STUB_SYSTEMD_RUN)
    _write_exec(os.path.join(stub_dir, "python3"), _STUB_PYTHON3)
    _write_exec(os.path.join(stub_dir, "vivado"), _STUB_VIVADO)
    run_capped_stub = os.path.join(stub_dir, "run_capped_stub.sh")
    _write_exec(run_capped_stub, _STUB_RUN_CAPPED)

    env = dict(os.environ)
    env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
    env["STUB_LOG"] = log_path
    env["GEN_EXPECT_PREFIX"] = os.path.join(root, "src")
    env["RUN_CAPPED"] = run_capped_stub
    # fix round 3, item 1: RUN_CAPPED is now refused unless this is also
    # set -- this test's own stub override needs it; the dedicated refusal
    # tests below deliberately build their OWN env without it.
    env["JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE"] = "1"
    return env


def _parse_log(log_path):
    """[(tool, (argv...), cwd), ...] in call order; () if the log was never written."""
    if not os.path.exists(log_path):
        return []
    rows = []
    with open(log_path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            tool = fields[0]
            cwd = ""
            argv = []
            for field in fields[1:]:
                if field.startswith("CWD="):
                    cwd = field[len("CWD="):]
                else:
                    argv.append(field)
            rows.append((tool, tuple(argv), cwd))
    return rows


def _snapshot(repo, file_path):
    """(porcelain status, file bytes) -- the "byte-unchanged" oracle, generalised
    to any repo/file pair so the mutant test can point it at a throwaway
    scratch clone instead of the live tree."""
    status = subprocess.run(["git", "status", "--porcelain"], cwd=repo,
                             capture_output=True, text=True).stdout
    with open(file_path, "rb") as f:
        content = f.read()
    return status, content


def _git_snapshot():
    """The live repo's own snapshot -- what every test except the mutant uses."""
    return _snapshot(REPO, LIVE_FK33_CARD)


def _dry_run_with_env(script_path, root, extra_env, extra_args=()):
    """A plain --dry-run invocation with a caller-chosen env (on top of the
    real environment, never the full stub env above) -- for the RUN_CAPPED
    override-guard tests, which must prove the refusal fires with NOTHING
    else in play. --dry-run keeps it fast and touches no filesystem; the
    override guard itself is NOT gated on --dry-run in either script (same
    as the root-location checks), so this is a faithful test of it."""
    env = dict(os.environ)
    env.update(extra_env)
    args = ["bash", script_path, "--dry-run", "--allow-scratch-root", root, *extra_args]
    return subprocess.run(args, cwd=REPO, env=env, capture_output=True, text=True,
                           timeout=30)


def _run_real(script_path, root, extra_args=(), allow_flags=()):
    # Sibling of <root>, never inside it: <root> itself must not exist before
    # the script runs (both scripts refuse a root that already exists and is
    # not empty), so the stub bin dir and call log cannot live under it.
    side = root + "_side"
    stub_dir = os.path.join(side, "stub_bin")
    log_path = os.path.join(side, "stub_calls.log")
    env = _build_stub_env(root, stub_dir, log_path)
    args = ["bash", script_path, "--allow-scratch-root", *allow_flags, root, *extra_args]
    result = subprocess.run(args, cwd=REPO, env=env, capture_output=True, text=True,
                             timeout=120)
    return result, _parse_log(log_path)


def _assert_each_logged_call_exactly_once(rows, must_include):
    """No (tool, argv) signature appears twice, and every (tool, predicate) pair
    in must_include -- predicate(argv_tuple) -> bool, an exact-membership test,
    never a naive substring-of-any-token match (git apply --check's argv
    contains the token "apply" too, so a substring check on "apply" alone
    would also match the --check call) -- matches exactly one row. This is
    what goes RED on the pre-fix scripts: run() executed the command once by
    itself, and the companion block executed the identical (tool, argv) pair
    again."""
    from collections import Counter
    counts = Counter((tool, argv) for tool, argv, _cwd in rows)
    dups = [sig for sig, n in counts.items() if n > 1]
    assert not dups, (
        f"these (tool, argv) calls ran more than once (double execution): {dups}\n"
        f"full call log: {rows}")
    for tool, predicate, label in must_include:
        hits = [1 for t, argv, _cwd in rows if t == tool and predicate(argv)]
        assert len(hits) == 1, (
            f"expected exactly one {tool} call matching {label!r}, got {len(hits)}\n"
            f"full call log: {rows}")


def _has(argv, *tokens):
    return all(any(t == a or a.endswith(t) for a in argv) for t in tokens)


def _lacks(argv, token):
    return not any(t == token for t in argv)


def _assert_generator_cwds_under_src(rows, root, generator_names):
    """Every logged python3 call for one of generator_names must have run with
    a cwd under <root>/src -- never the caller's cwd (the live-repo-corruption
    failure mode)."""
    src = os.path.join(root, "src")
    offenders = []
    for tool, argv, cwd in rows:
        if tool != "python3":
            continue
        if not any(any(name in a for name in generator_names) for a in argv):
            continue
        if not (cwd == src or cwd.startswith(src + os.sep)):
            offenders.append((argv, cwd))
    assert not offenders, (
        f"generator(s) invoked with a cwd NOT under {src}: {offenders}")


# ---- run_ooc27.sh -------------------------------------------------------------

def test_ooc27_real_run_executes_every_command_exactly_once(tmp_path):
    root = str(tmp_path / "root")
    before = _git_snapshot()
    result, rows = _run_real(RUN_OOC27, root,
                              extra_args=["xcvu35p-fsvh2104-2L-e", "1G"])
    after = _git_snapshot()

    assert before == after, "the live repo must be byte-unchanged by this run"
    assert "JCOOC27_DONE" in result.stdout, result.stdout + result.stderr

    _assert_each_logged_call_exactly_once(rows, must_include=[
        ("git", lambda a: _has(a, "apply", "--check"), "apply --check"),
        ("git", lambda a: _has(a, "apply") and _lacks(a, "--check"), "apply (real)"),
        ("python3", lambda a: _has(a, "gen_fk33_card.py"), "gen_fk33_card.py"),
        ("python3", lambda a: _has(a, "gen_ooc27_top.py"), "gen_ooc27_top.py"),
        ("vivado", lambda a: _has(a, "-mode"), "-mode"),
    ])
    _assert_generator_cwds_under_src(rows, root, ("gen_fk33_card.py",))
    # gen_ooc27_top.py takes $SRC as an explicit argument, not cwd-dependent,
    # but it must still have run from under <root> somewhere sane (not fatal
    # to this test either way; the exactly-once check above is what matters
    # for this one).


# ---- fix round 3, item 1: RUN_CAPPED's override guard -----------------------

def _write_bogus_run_capped(tmp_path):
    bogus = str(tmp_path / "bogus_run_capped.sh")
    _write_exec(bogus, "#!/usr/bin/env bash\nexec \"$@\"\n")
    return bogus


def test_ooc27_bare_run_capped_override_is_refused(tmp_path):
    root = str(tmp_path / "root")
    bogus = _write_bogus_run_capped(tmp_path)
    r = _dry_run_with_env(RUN_OOC27, root, {"RUN_CAPPED": bogus},
                           extra_args=["xcvu35p-fsvh2104-2L-e", "1G"])
    assert r.returncode != 0, r.stdout + r.stderr
    assert "JCOOC27_FAIL" in r.stdout
    assert "RUN_CAPPED" in r.stdout
    assert "JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE" in r.stdout
    assert not os.path.exists(root), "a refused run must not create <root>"


def test_ooc27_run_capped_override_allowed_with_the_test_flag(tmp_path):
    root = str(tmp_path / "root")
    bogus = _write_bogus_run_capped(tmp_path)
    r = _dry_run_with_env(RUN_OOC27, root,
                           {"RUN_CAPPED": bogus, "JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE": "1"},
                           extra_args=["xcvu35p-fsvh2104-2L-e", "1G"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "JCOOC27_FAIL" not in r.stdout


def test_ooc27_memory_budget_line_prints_effective_run_capped(tmp_path):
    root = str(tmp_path / "root")
    r = _dry_run_with_env(RUN_OOC27, root, {}, extra_args=["xcvu35p-fsvh2104-2L-e", "1G"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "run_capped=" in r.stdout and "run_capped.sh" in r.stdout


def test_card_bare_run_capped_override_is_refused(tmp_path):
    root = str(tmp_path / "root")
    bogus = _write_bogus_run_capped(tmp_path)
    r = _dry_run_with_env(RUN_CARD, root, {"RUN_CAPPED": bogus},
                           extra_args=["xcvu35p-fsvh2104-2L-e"])
    assert r.returncode != 0, r.stdout + r.stderr
    assert "JCCARD_FAIL" in r.stdout
    assert "RUN_CAPPED" in r.stdout
    assert "JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE" in r.stdout
    assert not os.path.exists(root), "a refused run must not create <root>"


def test_card_run_capped_override_allowed_with_the_test_flag(tmp_path):
    root = str(tmp_path / "root")
    bogus = _write_bogus_run_capped(tmp_path)
    r = _dry_run_with_env(RUN_CARD, root,
                           {"RUN_CAPPED": bogus, "JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE": "1"},
                           extra_args=["xcvu35p-fsvh2104-2L-e"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "JCCARD_FAIL" not in r.stdout


def test_card_memory_budget_line_prints_effective_run_capped(tmp_path):
    root = str(tmp_path / "root")
    r = _dry_run_with_env(RUN_CARD, root, {}, extra_args=["xcvu35p-fsvh2104-2L-e"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "run_capped=" in r.stdout and "run_capped.sh" in r.stdout


# ---- fix round 3, item 2: the oracle, forced to catch a real corruption -----

def test_oracle_catches_a_generator_that_actually_corrupts_the_wrong_tree(tmp_path):
    """The RED demonstrations above never reach the generator stage (the
    pre-fix scripts die at the double `git apply` first), and even this
    file's own protective python3 stub refuses to write outside
    $GEN_EXPECT_PREFIX -- so neither the "live repo unchanged" nor the
    "generator cwd under $SRC" oracle is ever forced to catch a REAL
    corruption anywhere above. This test forces exactly that: a one-line
    mutant fragment (never run_ooc27.sh or run_card.sh) that skips the
    git/levers step entirely and calls a PERMISSIVE python3 stub -- one
    that writes wherever its cwd is, no prefix guard at all, i.e. what the
    real, unstubbed generator actually does -- with cwd set to a throwaway
    `git clone` of this repo (never the live tree). Both oracles must flag
    it, or they have no teeth."""
    scratch_repo = str(tmp_path / "scratch_repo")
    subprocess.run(["git", "clone", "--quiet", REPO, scratch_repo],
                    check=True, capture_output=True, text=True, timeout=120)
    scratch_fk33_card = os.path.join(scratch_repo, "hw", "fk33", "rtl", "fk33_card.vhd")

    side = str(tmp_path / "mutant_side")
    stub_dir = os.path.join(side, "stub_bin")
    log_path = os.path.join(side, "stub_calls.log")
    os.makedirs(stub_dir, exist_ok=True)
    _write_exec(os.path.join(stub_dir, "python3"), _STUB_PYTHON3_PERMISSIVE)
    env = dict(os.environ)
    env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
    env["STUB_LOG"] = log_path

    before = _snapshot(scratch_repo, scratch_fk33_card)
    # the mutant: no git step at all, and the generator call has NO `cd` --
    # cwd is the scratch clone's own root, exactly the dangerous "invoked
    # from the repo root" case, reproduced on a disposable clone.
    mutant_fragment = "python3 hw/fk33/gen_fk33_card.py\n"
    mutant_result = subprocess.run(["bash", "-c", mutant_fragment], cwd=scratch_repo,
                                    env=env, capture_output=True, text=True, timeout=30)
    after = _snapshot(scratch_repo, scratch_fk33_card)

    assert mutant_result.returncode == 0, mutant_result.stdout + mutant_result.stderr
    assert before != after, (
        "the mutant was supposed to corrupt the scratch clone's "
        "fk33_card.vhd -- if THIS assertion fails, the mutant itself is "
        "broken, not evidence that the real scripts are safe")

    rows = _parse_log(log_path)
    assert rows and rows[0][0] == "python3"
    never_used_root = str(tmp_path / "root_never_created_by_the_mutant")
    raised = False
    try:
        _assert_generator_cwds_under_src(rows, never_used_root, ("gen_fk33_card.py",))
    except AssertionError:
        raised = True
    assert raised, (
        "the cwd-under-$SRC oracle must flag this mutant's wrong-cwd "
        "generator call (cwd was the scratch clone's root, not "
        f"{never_used_root}/src) -- if it does not raise, it has no teeth")


# ---- run_card.sh ---------------------------------------------------------------

def test_card_real_run_executes_every_command_exactly_once(tmp_path):
    root = str(tmp_path / "root")
    before = _git_snapshot()
    result, rows = _run_real(RUN_CARD, root,
                              extra_args=["xcvu35p-fsvh2104-2L-e"],
                              allow_flags=["--allow-llama-server"])
    after = _git_snapshot()

    assert before == after, "the live repo must be byte-unchanged by this run"
    assert "JCCARD_DONE" in result.stdout, result.stdout + result.stderr

    _assert_each_logged_call_exactly_once(rows, must_include=[
        ("git", lambda a: _has(a, "apply", "--check"), "apply --check"),
        ("git", lambda a: _has(a, "apply") and _lacks(a, "--check"), "apply (real)"),
        ("git", lambda a: _has(a, "rev-parse"), "rev-parse"),
        ("sha256sum", lambda a: _has(a, "build12_levers_off.patch"), "sha256sum(patch)"),
        ("python3", lambda a: _has(a, "gen_fk33_card.py"), "gen_fk33_card.py"),
        ("python3", lambda a: _has(a, "gen_jc_card.py"), "gen_jc_card.py"),
        ("vivado", lambda a: _has(a, "-mode"), "-mode"),
    ])
    _assert_generator_cwds_under_src(rows, root, ("gen_fk33_card.py", "gen_jc_card.py"))
