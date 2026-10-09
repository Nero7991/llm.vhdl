"""hw/jc/host/jc_bc_lane.sh --dry-run: the BC-250 broker lane and the between-sequence GDN
re-zero, checked without a board, a BMC, a broker or ssh.

    python3 -m pytest -q hw/jc/host/test_jc_bc_lane.py

The dry run prints the remote script (prefixed `DRYRUN| `) and runs nothing.  The remote
script is also run for real here, under bash, against FAKE python3/coe_load/broker
stand-ins on PATH, to check the gating logic (a failed zero must stop before the broker is
restarted, and the verdict is the anchored sentinel).
"""
import os, re, shutil, stat, subprocess, tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "jc_bc_lane.sh")

ENV = dict(JC_BC="user@bc250.invalid", JC_BMC="192.0.2.1", JC_BCW="/home/user/jc27b_run",
           JC_BC_MAN0="/home/user/jc_models/qwen38-27b-card0-b0-32/manifest.json",
           JC_BC_MAN1="/home/user/jc_models/qwen38-27b-card1-b33-63/manifest.json")


def run(args, **over):
    env = {k: v for k, v in os.environ.items() if not k.startswith("JC_")}
    env.update(ENV)
    env.update(over)
    env = {k: v for k, v in env.items() if v is not None}
    return subprocess.run(["bash", SCRIPT] + args, env=env, capture_output=True, text=True,
                          timeout=60)


def remote_of(out):
    return "\n".join(l[len("DRYRUN| "):] for l in out.splitlines() if l.startswith("DRYRUN| "))


def test_rezero_dry_run_order_and_flags():
    p = run(["rezero", "--dry-run"])
    assert p.returncode == 0, p.stderr
    assert p.stdout.splitlines()[0] == "DRYRUN ssh user@bc250.invalid bash -s <<REMOTE"
    r = remote_of(p.stdout)
    tail = [l for l in r.splitlines() if re.match(r"^(stop_broker|zero_die|start_broker)$|^zero_die ", l)]
    assert tail == ["stop_broker", "zero_die 0 A", "zero_die 1 B", "start_broker"], tail
    assert 'tools/jc/coe_load.py load "$s"' in r and 'tools/jc/coe_load.py verify "$s"' in r
    assert '$W/card$1/side_gdn.json' in r
    # the die already holds the image: the zero is an append, and the default checkpoint
    # dir does not exist on the BC-250 (both MEASURED 2026-10-09)
    load = re.search(r'coe_load\.py load "\$s".*?\n.*?\n', r).group(0)
    assert "--append" in load and '--ckpt "$W/ckpt/' in load, load
    ver = re.search(r'coe_load\.py verify "\$s".*?\n.*?\n', r).group(0)
    assert "--append" not in ver and '--ckpt "$W/ckpt/' in ver, ver
    assert "--manifest A=/home/user/jc_models/qwen38-27b-card0-b0-32/manifest.json" in r
    assert "--manifest B=/home/user/jc_models/qwen38-27b-card1-b33-63/manifest.json" in r
    assert "--allow-image-read" not in r
    assert "kill -INT" in r
    for bad in ("pkill", "pgrep", "rm ", "/proc/$p/cmdline"):
        assert bad not in r, bad
    assert "readlink /proc/$p/exe" in r and "readlink /proc/$p/cwd" in r
    assert not re.search(r"^JCLANE_", p.stdout, re.M), "a dry run printed a sentinel"


def test_swapped_dies_and_start_stop():
    p = run(["rezero", "--dry-run"], JC_DIE0="B", JC_DIE1="A")
    r = remote_of(p.stdout)
    assert "zero_die 0 B" in r and "zero_die 1 A" in r
    assert "--manifest B=/home/user/jc_models/qwen38-27b-card0-b0-32/manifest.json" in r
    s = remote_of(run(["start", "--dry-run"]).stdout).splitlines()
    assert s[-2:] == ["start_broker", 'echo "JCLANE_DONE start"'], s[-2:]
    t = run(["stop", "--dry-run"], JC_BC_MAN0=None, JC_BC_MAN1=None)
    assert t.returncode == 0, t.stderr
    assert remote_of(t.stdout).splitlines()[-2:] == ["stop_broker", 'echo "JCLANE_DONE stop"']


def test_tilde_manifests_expand_on_the_bc250():
    p = run(["start", "--dry-run"], JC_BC_MAN0="~/jc_models/qwen38-27b-card0-b0-32/manifest.json",
            JC_BC_MAN1="~/jc_models/qwen38-27b-card1-b33-63/manifest.json")
    r = remote_of(p.stdout)
    assert '--manifest A="$HOME"/jc_models/qwen38-27b-card0-b0-32/manifest.json' in r, r
    assert '--manifest B="$HOME"/jc_models/qwen38-27b-card1-b33-63/manifest.json' in r
    # and bash really expands it: echo the argument through the same quoting
    line = [l for l in r.splitlines() if "--manifest A=" in l][0]
    arg = line.split("--manifest A=")[1].split()[0]
    out = subprocess.run(["bash", "-c", "printf %s " + arg], env=dict(os.environ, HOME="/h"),
                         capture_output=True, text=True).stdout
    assert out == "/h/jc_models/qwen38-27b-card0-b0-32/manifest.json", out


def test_refusals():
    assert run(["bogus"]).returncode == 2
    assert run([]).returncode == 2
    p = run(["rezero", "--dry-run"], JC_BMC=None)
    assert p.returncode == 2 and "JC_BMC is not set" in p.stderr
    p = run(["start", "--dry-run"], JC_BC_MAN1=None)
    assert p.returncode == 2 and "JC_BC_MAN1" in p.stderr
    p = run(["rezero", "--dry-run"], JC_BCW="/tmp/x")
    assert p.returncode == 2 and "not under /tmp" in p.stderr
    p = run(["rezero", "--dry-run"], JC_DIE0="A", JC_DIE1="A")
    assert p.returncode == 2


def _fake_bin(d, name, body):
    p = os.path.join(d, name)
    with open(p, "w") as f:
        f.write("#!/usr/bin/env bash\n" + body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


@pytest.fixture
def scratch():
    """Not pytest's tmp_path: that is under /tmp, which the script refuses for JC_BCW."""
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    d = tempfile.mkdtemp(prefix="jclane", dir=base)
    yield __import__("pathlib").Path(d)
    shutil.rmtree(d, ignore_errors=True)


def _exec_remote(tmp_path, verify_ok):
    """Run the rezero remote script under bash with python3 replaced by a stub that logs its
    argv, so the ORDER and the GATES are exercised, not just printed."""
    repo = tmp_path / "repo"; (repo / "tools/jc").mkdir(parents=True)
    w = tmp_path / "w"
    for n in (0, 1):
        (w / ("card%d" % n)).mkdir(parents=True)
        (w / ("card%d" % n) / "side_gdn.json").write_text("{}")
    bindir = tmp_path / "bin"; bindir.mkdir()
    log = tmp_path / "calls.log"
    _fake_bin(str(bindir), "python3", """
echo "$*" >> %s
case "$1 $2" in
  "tools/jc/coe_load.py load") echo "JCLOAD_DONE last=1 committed=1" ;;
  "tools/jc/coe_load.py verify") %s ;;
  "tools/jc/jc_broker.py serve") echo "JCBROKER_READY sock" ;;
esac
""" % (log, 'echo "JCVERIFY_PASS 2 pieces, 0 bad"' if verify_ok else 'echo "JCVERIFY_FAIL 2 pieces, 1 bad"'))
    p = run(["rezero", "--dry-run"], JC_BC_REPO=str(repo), JC_BCW=str(w))
    assert p.returncode == 0, p.stderr
    script = remote_of(p.stdout)
    env = dict(os.environ, PATH=str(bindir) + ":" + os.environ["PATH"], HOME=str(tmp_path))
    q = subprocess.run(["bash", "-s"], input=script, env=env, capture_output=True, text=True,
                       timeout=60)
    calls = log.read_text().splitlines() if log.exists() else []
    return q, calls


def test_remote_rezero_runs_in_order(scratch):
    q, calls = _exec_remote(scratch, True)
    assert re.search(r"^JCLANE_DONE rezero$", q.stdout, re.M), q.stdout + q.stderr
    kinds = [" ".join(c.split()[:2]) + " " + c.split()[c.split().index("--die") + 1]
             if "--die" in c.split() else " ".join(c.split()[:2]) for c in calls]
    assert kinds == ["tools/jc/coe_load.py load A", "tools/jc/coe_load.py verify A",
                     "tools/jc/coe_load.py load B", "tools/jc/coe_load.py verify B",
                     "tools/jc/jc_broker.py serve"], kinds


def test_remote_rezero_stops_before_the_broker_on_a_bad_verify(scratch):
    q, calls = _exec_remote(scratch, False)
    assert re.search(r"^JCLANE_FAIL GDN zero verify on die A", q.stdout, re.M), q.stdout
    assert not re.search(r"^JCLANE_DONE", q.stdout, re.M)
    assert not any("jc_broker.py" in c for c in calls), calls
