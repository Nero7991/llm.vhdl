"""hw/jc/host/jc_ctxtest.sh --dry-run: what the context test WOULD run, checked without a
board, a broker or a run_prompt binary.

    python3 -m pytest -q hw/jc/host/test_jc_ctxtest.py

The dry run must print every command (the run_prompt pair over the JC broker, each test
twice, a seam dump of every die after every run, the id comparison across repeats) and the
line-anchored verdict gate, must create nothing, and must never print a line that starts
with a CTXTEST_ sentinel: a waiter gating on `^CTXTEST_PASS` must not be able to mistake a
dry run for a pass.
"""
import os, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "jc_ctxtest.sh")

SOCK = "/nonexistent/jc_broker.sock"


def run(args, tmp_path, **env_over):
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("JC_") or k in ("REPEATS", "TESTS", "RUN_PROMPT", "JC_NO_REZERO"):
            del env[k]
    env.update(JC_SOCK=SOCK,
               JC_RUN0="/nonexistent/run/card0", JC_RUN1="/nonexistent/run/card1",
               JC_MAN0="/nonexistent/m0/manifest.json", JC_MAN1="/nonexistent/m1/manifest.json")
    env.update(env_over)
    p = subprocess.run(["bash", SCRIPT] + args, env=env, capture_output=True, text=True,
                       timeout=60)
    return p


def rp_lines(out):
    return [l for l in out.splitlines() if l.startswith("DRYRUN ") and "run_prompt" in l
            and "--help" not in l]


def test_pair_dry_run_commands(tmp_path):
    out_dir = str(tmp_path / "ctx")
    p = run(["pair", out_dir, "500", "--dry-run"], tmp_path)
    assert p.returncode == 0, p.stdout + p.stderr
    o = p.stdout
    rps = rp_lines(o)
    # input twice, output twice, in that order
    tags = [re.search(r"--ids-out \S*/(\w+)\.ids", l).group(1) for l in rps]
    assert tags == ["input_r1", "input_r2", "output_r1", "output_r2"], rps
    for l in rps:
        assert "--jc %s" % SOCK in l
        assert "--jc-die A" in l and "--jc-die2 B" in l
        assert "--v2" in l and "--seq-reset" in l and "--stop -1" in l
        assert "--dtbl /nonexistent/run/card0/token.dtbl" in l
        assert "--dtbl2 /nonexistent/run/card1/token.dtbl" in l
        assert "--manifest /nonexistent/m0/manifest.json" in l
        assert "--manifest2 /nonexistent/m1/manifest.json" in l
        assert "/dev/xdma" not in l and "--allow-hardware" not in l
    assert all("--max-new 1 " in l and "prompt_input.txt" in l for l in rps[:2])
    # N = 500 GOs: a 16-id prompt, then 500 - 16 + 1 = 485 generated ids
    assert all("--max-new 485 " in l and "prompt_output.txt" in l for l in rps[2:])
    # a seam dump of BOTH dies before the test and after EVERY run
    for tag in ("pre", "input_r1", "input_r2", "output_r1", "output_r2"):
        for d in ("A", "B"):
            assert re.search(r"^DRYRUN .*jc_seam\.py seam --sock %s --die %s .*%s_seam_%s\.txt"
                             % (re.escape(SOCK), d, tag, d), o, re.M), (tag, d)
    # the repeats are compared id for id
    for t in ("input", "output"):
        assert re.search(r"^DRYRUN cmp -s \S*/%s_r1\.ids \S*/%s_r2\.ids$" % (t, t), o, re.M), t
    # the verdict gate is line-anchored
    assert re.search(r"^DRYRUN gate grep -qE '\^CTXTEST_PASS' \S*/ctxtest\.log$", o, re.M), o
    assert re.search(r"^DRYRUN_DONE ", o, re.M)
    # and a dry run is never a verdict
    assert not re.search(r"^CTXTEST_", o, re.M)
    assert not os.path.exists(out_dir), "a dry run created the output directory"


def test_repeats_and_single(tmp_path):
    p = run(["single", str(tmp_path / "s"), "64", "--dry-run"], tmp_path, REPEATS="3",
            JC_DIE="B")
    assert p.returncode == 0, p.stdout + p.stderr
    rps = rp_lines(p.stdout)
    assert len(rps) == 6
    for l in rps:
        assert "--jc-die B" in l and "--jc-die2" not in l and "--dtbl2" not in l
    assert sum(1 for l in rps if "--max-new 49 " in l) == 3      # 64 - 16 + 1
    for r in (2, 3):
        assert re.search(r"^DRYRUN cmp -s \S*/input_r1\.ids \S*/input_r%d\.ids$" % r,
                         p.stdout, re.M)


def test_prep_hook_runs_before_every_run(tmp_path):
    p = run(["pair", str(tmp_path / "c"), "100", "--dry-run"], tmp_path,
            JC_PREP="echo zero-gdn")
    assert p.returncode == 0, p.stdout + p.stderr
    lines = p.stdout.splitlines()
    preps = [i for i, l in enumerate(lines) if l == "DRYRUN prep echo zero-gdn"]
    rps = [i for i, l in enumerate(lines) if l in rp_lines(p.stdout)]
    assert len(preps) == 4 and all(a < b for a, b in zip(preps, rps))


def test_gdn_rezero_is_the_default_prep(tmp_path):
    """Gap 4: the FK33 flow zeroes the GDN state before EVERY sequence (fk33_chat2.sh:131-135,
    one chat2 per ctxtest run).  Unset JC_PREP must mean the same on the JC: the BC-250 lane's
    rezero (stop broker, coe_load side_gdn.json on both dies, start broker) before every run."""
    p = run(["pair", str(tmp_path / "c"), "100", "--dry-run"], tmp_path)
    assert p.returncode == 0, p.stdout + p.stderr
    lines = p.stdout.splitlines()
    preps = [i for i, l in enumerate(lines)
             if re.match(r"^DRYRUN prep bash \S*/hw/jc/host/jc_bc_lane\.sh rezero$", l)]
    rps = [i for i, l in enumerate(lines) if l in rp_lines(p.stdout)]
    assert len(preps) == 4 and all(a < b for a, b in zip(preps, rps)), lines
    assert "GDN state is NOT re-zeroed" not in p.stdout


def test_no_rezero_only_when_asked(tmp_path):
    p = run(["pair", str(tmp_path / "c"), "100", "--dry-run"], tmp_path, JC_NO_REZERO="1")
    assert p.returncode == 0, p.stdout + p.stderr
    assert not any(l.startswith("DRYRUN prep") for l in p.stdout.splitlines())
    assert "GDN state is NOT re-zeroed" in p.stdout


def test_refusals(tmp_path):
    assert run(["triple", str(tmp_path / "x"), "500", "--dry-run"], tmp_path).returncode == 2
    p = run(["pair", str(tmp_path / "x"), "16", "--dry-run"], tmp_path)
    assert p.returncode != 0 and "not above" in p.stdout + p.stderr
    p = run(["pair", str(tmp_path / "x"), "500", "--dry-run"], tmp_path, JC_SOCK="")
    assert p.returncode != 0 and "JC_SOCK" in p.stdout + p.stderr


def test_real_path_gates_on_anchored_sentinel():
    src = open(SCRIPT).read()
    assert "grep -qE '^CTXTEST_PASS' \"$LOG\"" in src
    assert "grep -qE '^status .* err=1'" in src
    assert "/dev/xdma" not in src
