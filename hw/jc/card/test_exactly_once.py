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


def _git_snapshot():
    """(porcelain status, live fk33_card.vhd bytes) -- the "byte-unchanged" oracle."""
    status = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                             capture_output=True, text=True).stdout
    with open(LIVE_FK33_CARD, "rb") as f:
        content = f.read()
    return status, content


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


def test_ooc27_real_run_writes_nothing_outside_root(tmp_path):
    root = str(tmp_path / "root")
    before = _git_snapshot()
    _run_real(RUN_OOC27, root, extra_args=["xcvu35p-fsvh2104-2L-e", "1G"])
    after = _git_snapshot()
    assert before == after


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


def test_card_real_run_writes_nothing_outside_root(tmp_path):
    root = str(tmp_path / "root")
    before = _git_snapshot()
    _run_real(RUN_CARD, root, extra_args=["xcvu35p-fsvh2104-2L-e"],
              allow_flags=["--allow-llama-server"])
    after = _git_snapshot()
    assert before == after
