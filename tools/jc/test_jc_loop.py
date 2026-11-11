"""tools/jc/test_jc_loop.py -- jc_loop.py over jc_sim_broker --loop against run_prompt over the
same broker without --loop: the ids must be identical (plan 2026-11-04 Task 7). NO HARDWARE."""
import os, signal, subprocess, sys, tempfile
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import gen_tok_loop_vec as GV  # noqa: E402
import jc_loop as L  # noqa: E402

SERVER = os.path.join(REPO, "server")


@pytest.fixture(scope="module", autouse=True)
def build():
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def broker(work, extra):
    sock = os.path.join(work, "s.sock")
    b = subprocess.Popen([GV.BROKER, sock, os.path.join(work, "b.log"), "--kv-maxpos", "16384",
                          "--dies", "A,B"] + extra, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert b.stdout.readline().startswith("JCSIMBROKER_READY")
    return b, sock


def ref_ids(prompt, max_new, pair):
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/regress_scratch"))
    GV.write_programs(work)
    ids, _ = GV.run_case(work, prompt, max_new, -1, pair, None)
    return ids


def loop_ids(prompt, max_new, pair, extra=()):
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/regress_scratch"))
    GV.write_programs(work)
    b, sock = broker(work, ["--loop"] + (["--loop-pair", "A,B"] if pair else []) + list(extra))
    try:
        with open(os.path.join(work, "p.txt"), "w") as f:
            f.write(" ".join(map(str, prompt)) + "\n")
        args = [GV.RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2", "--seq-reset",
                "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", GV.MAN_A, "--max-new", "1",
                "--stop", "-1", "--ids-out", "open.txt", "--open-only"]
        if pair:
            args += ["--jc-die2", "B", "--dtbl2", "b.dtbl", "--rel2", "b.rel", "--manifest2", GV.MAN_B]
        r = subprocess.run(args, cwd=work, capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, r.stdout + r.stderr
        cmd = [sys.executable, os.path.join(HERE, "jc_loop.py"), "--sock", sock, "--die", "A",
               "--prompt", os.path.join(work, "p.txt"), "--max-new", str(max_new), "--synthetic",
               "--ids-out", os.path.join(work, "ids.txt"), "--timeout-s", "300"]
        if pair:
            cmd += ["--die2", "B"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        last = r.stdout.strip().splitlines()[-1]
        return last, [int(x) for x in open(os.path.join(work, "ids.txt")).read().split()], r.stdout
    finally:
        b.send_signal(signal.SIGTERM); b.wait(timeout=10)


def test_single_die_ids_equal_run_prompt():
    want = ref_ids([1, 2, 3], 5, False)
    last, got, _ = loop_ids([1, 2, 3], 5, False)
    assert last.startswith("JCLOOP_DONE") and got == want


def test_pair_ids_equal_run_prompt():
    want = ref_ids([1, 2, 3], 5, True)
    last, got, _ = loop_ids([1, 2, 3], 5, True)
    assert last.startswith("JCLOOP_DONE") and got == want


def test_pair_with_a_corrupted_frame_resends_and_matches():
    want = ref_ids([1, 2, 3], 5, True)
    last, got, out = loop_ids([1, 2, 3], 5, True, ["--loop-drop", "3"])
    assert last.startswith("JCLOOP_DONE") and got == want
    assert "RESEND" in out


def test_timing_line_counts_positions():
    _, got, out = loop_ids([1, 2, 3], 5, False)
    assert "timing %d GOs" % (3 + len(got) - 1) in out


def test_broker_call_does_not_retry_a_write(monkeypatch):
    """finding 10: a WindowUnknown retry is safe only for rd32. A write (wr32, wrn) gets one
    attempt through Broker.call and raises immediately, never a blind retry that could
    double-apply (a shifted ROW_DATA/PROMPT_DATA window, a re-armed NEXT_TOKEN)."""
    b = L.Broker.__new__(L.Broker)
    calls = []

    def fake_send(req):
        calls.append(req["op"])
        if req["op"] == "rd32" and len(calls) == 1:
            return {"ok": False, "err": "WindowUnknown"}
        if req["op"] == "wr32":
            return {"ok": False, "err": "WindowUnknown"}
        return {"ok": True, "val": 0}

    monkeypatch.setattr(b, "_send", fake_send)
    r = b.call({"op": "rd32", "off": 0})
    assert r["ok"] and calls.count("rd32") == 2   # a read retried past one WindowUnknown
    calls.clear()
    with pytest.raises(RuntimeError):
        b.call({"op": "wr32", "off": 0, "val": 1})
    assert calls == ["wr32"]   # a write got exactly one attempt, then raised
