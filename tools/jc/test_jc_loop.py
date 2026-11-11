"""tools/jc/test_jc_loop.py -- jc_loop.py over jc_sim_broker --loop against run_prompt over the
same broker without --loop: the ids must be identical (plan 2026-11-04 Task 7). The final fix
pass (2026-11-11) adds the failure paths: a die stopping with an error, a die left running, the
WindowUnknown retry of absolute writes and the read-back verification of CTRL pulses, and the
ABORT that every unclean exit sends to both dies (final review I1, I2; finding 10 reversed for
absolute writes). NO HARDWARE."""
import os, signal, subprocess, sys, tempfile, time
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import gen_tok_loop_vec as GV  # noqa: E402
import jc_loop as L  # noqa: E402

SERVER = os.path.join(REPO, "server")
SCRATCH = os.path.expanduser("~/regress_scratch")
STATE_RUN, STATE_STOPPED = 1, 2
R_MAX_NEW, R_ABORT, R_ENGINE_ERR = 1, 4, 5


@pytest.fixture(scope="module", autouse=True)
def build():
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    os.makedirs(SCRATCH, exist_ok=True)


def broker(work, extra):
    sock = os.path.join(work, "s.sock")
    b = subprocess.Popen([GV.BROKER, sock, os.path.join(work, "b.log"), "--kv-maxpos", "16384",
                          "--dies", "A,B"] + extra, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = b.stdout.readline()
    assert line.startswith("JCSIMBROKER_READY"), line + b.stderr.read()
    return b, sock


def ref_ids(prompt, max_new, pair):
    with tempfile.TemporaryDirectory(dir=SCRATCH) as work:
        GV.write_programs(work)
        ids, _ = GV.run_case(work, prompt, max_new, -1, pair, None)
        return ids


def status(sock, die):
    """(state, reason) of a die's loop, read over the broker as a second client."""
    d = L.Die(L.Broker(sock), die, 0x20000)
    s = d.rd("STATUS")
    d.br.k.close()
    return s & 3, (s >> 8) & 0xFF


class Run:
    """One jc_loop run: last line, ids (None when it wrote none), stdout, the broker log,
    wall time, and whatever `after(sock)` returned while the broker was still up."""


def loop_ids(prompt, max_new, pair, extra=(), jc_args=(), before=None, after=None, timeout_s=300):
    with tempfile.TemporaryDirectory(dir=SCRATCH) as work:
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
            if before:
                before(sock)
            cmd = [sys.executable, os.path.join(HERE, "jc_loop.py"), "--sock", sock, "--die", "A",
                   "--prompt", os.path.join(work, "p.txt"), "--max-new", str(max_new), "--synthetic",
                   "--ids-out", os.path.join(work, "ids.txt"), "--timeout-s", str(timeout_s)] + list(jc_args)
            if pair:
                cmd += ["--die2", "B"]
            t0 = time.time()
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            out = Run()
            out.wall = time.time() - t0
            out.stdout = r.stdout + r.stderr
            lines = r.stdout.strip().splitlines()
            out.last = lines[-1] if lines else ""
            idf = os.path.join(work, "ids.txt")
            # a failing run writes no ids file: report jc_loop's own words, not a FileNotFoundError
            out.ids = [int(x) for x in open(idf).read().split()] if os.path.exists(idf) else None
            out.after = after(sock) if after else None
            out.log = open(os.path.join(work, "b.log")).read()
            return out
        finally:
            b.send_signal(signal.SIGTERM); b.wait(timeout=10)


def done(o, want):
    assert o.last.startswith("JCLOOP_DONE"), o.stdout
    assert o.ids == want, o.stdout


def test_single_die_ids_equal_run_prompt():
    done(loop_ids([1, 2, 3], 5, False), ref_ids([1, 2, 3], 5, False))


def test_pair_ids_equal_run_prompt():
    done(loop_ids([1, 2, 3], 5, True), ref_ids([1, 2, 3], 5, True))


def test_pair_with_a_corrupted_frame_resends_and_matches():
    o = loop_ids([1, 2, 3], 5, True, ["--loop-drop", "3"])
    done(o, ref_ids([1, 2, 3], 5, True))
    assert "RESEND" in o.stdout


def test_timing_line_counts_positions():
    o = loop_ids([1, 2, 3], 5, False)
    assert "timing %d GOs" % (3 + len(o.ids) - 1) in o.stdout


def both(sock):
    return status(sock, "A"), status(sock, "B")


def test_die_b_error_stops_the_run_and_aborts_die_a():
    """I1: die B stops ENGINE_ERR at position 4 while A waits on it. The run must end at once
    (not at --timeout-s) with JCLOOP_FAIL naming B's reason, and A must be ABORTed."""
    o = loop_ids([1, 2, 3], 8, True, ["--loop-fail", "B:4:%d" % R_ENGINE_ERR], timeout_s=30, after=both)
    assert o.last.startswith("JCLOOP_FAIL") and "ENGINE_ERR" in o.last, o.stdout
    assert o.wall < 20, "the run waited %.1f s: it did not stop on B's error" % o.wall
    (sa, ra), (sb, rb) = o.after
    assert (sb, rb) == (STATE_STOPPED, R_ENGINE_ERR), o.after
    assert (sa, ra) == (STATE_STOPPED, R_ABORT), "die A left %s: never aborted" % (o.after[0],)


def test_die_a_error_stops_the_run_and_aborts_die_b():
    o = loop_ids([1, 2, 3], 8, True, ["--loop-fail", "A:2:%d" % R_ENGINE_ERR], timeout_s=30, after=both)
    assert o.last.startswith("JCLOOP_FAIL") and "ENGINE_ERR" in o.last, o.stdout
    (sa, ra), (sb, rb) = o.after
    assert (sa, ra) == (STATE_STOPPED, R_ENGINE_ERR) and (sb, rb) == (STATE_STOPPED, R_ABORT), o.after


def test_a_die_reading_idle_mid_run_fails_and_aborts_the_other():
    """I1: die B drops to IDLE at position 4 (a reset or reload under the run). The run ends
    at once with JCLOOP_FAIL, and A is ABORTed."""
    o = loop_ids([1, 2, 3], 8, True, ["--loop-fail", "B:4:0"], timeout_s=30, after=both)
    assert o.last.startswith("JCLOOP_FAIL") and "die B reads IDLE" in o.last, o.stdout
    assert o.wall < 20, o.wall
    assert o.after[0] == (STATE_STOPPED, R_ABORT), o.after


def start_stale_b(sock):
    """A previous client left die B running a different run (prompt 7 8 9, MAX_NEW 2) and
    TMO_LINK 1234, then went away."""
    d = L.Die(L.Broker(sock), "B", 0x20000)
    for reg, v in (("PROMPT_LEN", 3), ("MAX_NEW", 2), ("ROLE", 2), ("ROW_SRC", 2), ("TMO_LINK", 1234),
                   ("PROMPT_ADDR", 0)):
        d.wr(reg, v)
    d.wrn_fix("PROMPT_DATA", [7, 8, 9])
    d.br.call({"die": "B", "op": "wr32", "off": 0x20000 + L.REG["CTRL"], "val": 1})
    assert d.rd("STATUS") & 3 == STATE_RUN
    d.br.k.close()


def tmo_b(sock):
    d = L.Die(L.Broker(sock), "B", 0x20000)
    v = d.rd("TMO_LINK")
    d.br.k.close()
    return v


def test_a_running_die_is_aborted_before_setup():
    """I1: a die still running from an earlier client is ABORTed (and waited for) before
    setup; otherwise its START is ignored and it carries on with the stale run."""
    o = loop_ids([1, 2, 3], 5, True, before=start_stale_b, after=tmo_b)
    done(o, ref_ids([1, 2, 3], 5, True))
    assert "die B was running" in o.stdout, o.stdout


def test_setup_writes_die_b_tmo_link_max():
    """I2: setup writes die B's TMO_LINK 0xFFFFFFFF, whatever an earlier client left there."""
    o = loop_ids([1, 2, 3], 5, True, before=start_stale_b, after=tmo_b)
    done(o, ref_ids([1, 2, 3], 5, True))
    assert o.after == 0xFFFFFFFF, hex(o.after)


@pytest.mark.parametrize("mode", ["lost", "ran"])
def test_absolute_write_is_retried_on_window_unknown(mode):
    """Ruling 2026-11-11 (finding 10 reversed for absolute writes): A's second LINK_CREDIT
    write (the first relayed credit) answers WindowUnknown; it is written again and the run
    completes with the reference ids."""
    o = loop_ids([1, 2, 3], 5, True, ["--fail-wr", "A:0x20074:2:%s" % mode])
    done(o, ref_ids([1, 2, 3], 5, True))
    assert "A loop wr32 0x20074 FAILED %s" % mode in o.log


def test_out_ack_is_retried_on_window_unknown():
    o = loop_ids([1, 2, 3], 5, False, ["--fail-wr", "A:0x20064:1:lost"])
    done(o, ref_ids([1, 2, 3], 5, False))
    assert "A loop wr32 0x20064 FAILED lost" in o.log


def ctrl_writes(log, die):
    return sum(1 for l in log.splitlines() if l.startswith("%s loop wr32 0x2000c" % die))


def test_start_that_landed_is_verified_not_retried():
    """A's START answers WindowUnknown but ran: read-back shows it running; no second write."""
    o = loop_ids([1, 2, 3], 5, True, ["--fail-wr", "A:0x2000c:1:ran"])
    done(o, ref_ids([1, 2, 3], 5, True))
    assert "START answered WindowUnknown; read-back shows it landed" in o.stdout, o.stdout
    clean = loop_ids([1, 2, 3], 5, True)       # A's other CTRL writes are its ROW_READYs (host rows)
    assert ctrl_writes(o.log, "A") == ctrl_writes(clean.log, "A"), o.log


def test_start_that_was_lost_fails_without_a_retry_and_aborts():
    o = loop_ids([1, 2, 3], 5, True, ["--fail-wr", "A:0x2000c:1:lost"], after=both)
    # refused at the read-back itself, not later by the IDLE check (pymut J7 survived the looser form)
    assert o.last.startswith("JCLOOP_FAIL") and "CTRL START answered WindowUnknown and the read-back" in o.last, o.stdout
    assert o.ids is None
    assert ctrl_writes(o.log, "A") == 2, o.log           # the lost START, then the exit's ABORT
    assert o.after[1] == (STATE_STOPPED, R_ABORT), o.after   # B was started: aborted on the way out


def test_row_ready_that_landed_is_verified():
    """Single die, host rows: A's second CTRL write (the first ROW_READY) answers WindowUnknown
    but ran; read-back shows the position moved on, the run completes, nothing re-sent."""
    o = loop_ids([1, 2, 3], 5, False, ["--fail-wr", "A:0x2000c:2:ran"])
    done(o, ref_ids([1, 2, 3], 5, False))
    assert "ROW_READY answered WindowUnknown; read-back shows it landed" in o.stdout, o.stdout


def nth_resend():
    """Which of A's CTRL writes is the RESEND in the --loop-drop 3 pair run (START and the
    ROW_READYs come before it): read from a clean run's own log and stdout order."""
    o = loop_ids([1, 2, 3], 5, True, ["--loop-drop", "3"])
    k = 0
    for l in o.log.splitlines():
        if l.startswith("A loop wr32 0x2000c"):
            k += 1
        if l.startswith("A loop rd32 0x20098"):          # resend() reads RESENDS just before it
            return k + 1
    raise AssertionError("no RESENDS read in the drop run: " + o.stdout)


def test_resend_that_landed_is_verified():
    """Pair with a corrupted frame: A's CTRL write that carries the RESEND answers WindowUnknown
    but ran; read-back sees RESENDS move, the run completes with the reference ids."""
    o = loop_ids([1, 2, 3], 5, True, ["--loop-drop", "3", "--fail-wr", "A:0x2000c:%d:ran" % nth_resend()])
    done(o, ref_ids([1, 2, 3], 5, True))
    assert "RESEND answered WindowUnknown; read-back shows it landed" in o.stdout, o.stdout
    clean = loop_ids([1, 2, 3], 5, True, ["--loop-drop", "3"])
    assert ctrl_writes(o.log, "A") == ctrl_writes(clean.log, "A"), o.log


def test_next_token_window_unknown_fails_and_aborts_both():
    """NEXT_TOKEN is not idempotent (a duplicate re-arms it): never retried. The run fails and
    the exit path ABORTs both dies (I1), which the old code left running."""
    o = loop_ids([1, 2, 3], 5, True, ["--fail-wr", "A:0x20048:1:lost"], after=both)
    assert o.last.startswith("JCLOOP_FAIL"), o.stdout
    assert o.ids is None
    assert o.after == ((STATE_STOPPED, R_ABORT), (STATE_STOPPED, R_ABORT)), o.after


def test_broker_call_retries_a_write_only_when_asked(monkeypatch):
    """A WindowUnknown retry is safe for rd32 and for an absolute write (retry_write=True); any
    other write gets exactly one attempt and raises."""
    b = L.Broker.__new__(L.Broker)
    calls = []

    def fake_send(req):
        calls.append(req["op"])
        if len(calls) == 1:
            return {"ok": False, "err": "WindowUnknown"}
        return {"ok": True, "val": 0}

    monkeypatch.setattr(b, "_send", fake_send)
    monkeypatch.setattr(L.time, "sleep", lambda s: None)
    assert b.call({"op": "rd32", "off": 0})["ok"] and calls == ["rd32", "rd32"]
    calls.clear()
    with pytest.raises(L.WindowUnknown):
        b.call({"op": "wr32", "off": 0, "val": 1})
    assert calls == ["wr32"]
    calls.clear()
    assert b.call({"op": "wr32", "off": 0, "val": 1}, retry_write=True)["ok"] and calls == ["wr32", "wr32"]


def test_die_wr_refuses_ctrl_and_classifies_registers():
    assert L.ABSOLUTE >= {"OUT_ACK", "LINK_CREDIT", "ROW_EXP", "ROW_ADDR", "PROMPT_LEN", "MAX_NEW",
                          "STOP_ID0", "ROLE", "ROW_SRC", "RESEND_CAP", "TMO_LINK"}
    assert "NEXT_TOKEN" not in L.ABSOLUTE and "CTRL" not in L.ABSOLUTE
    d = L.Die(None, "A", 0x20000)
    with pytest.raises(ValueError):
        d.wr("CTRL", 1)


def test_dump_xout_equals_run_prompts():
    """Plan Task 8 Step 1: jc_loop --dump-xout after the loop equals run_prompt --dump-xout
    after the host path, for the same prompt (single die, synthetic rows on both)."""
    with tempfile.TemporaryDirectory(dir=SCRATCH) as work:
        GV.write_programs(work)
        with open(os.path.join(work, "p.txt"), "w") as f:
            f.write("1 2 3 4\n")
        b, sock = broker(work, [])
        try:
            r = subprocess.run([GV.RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2",
                                "--seq-reset", "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", GV.MAN_A,
                                "--max-new", "1", "--stop", "-1", "--ids-out", "ref.ids",
                                "--dump-xout", "ref.xout"], cwd=work, capture_output=True, text=True, timeout=300)
            assert r.returncode == 0, r.stdout + r.stderr
        finally:
            b.send_signal(signal.SIGTERM); b.wait(timeout=10)
        dump = os.path.join(work, "loop.xout")
        o = loop_ids([1, 2, 3, 4], 1, False, jc_args=["--dump-xout", dump])
        assert o.last.startswith("JCLOOP_DONE"), o.stdout
        ref = open(os.path.join(work, "ref.xout")).read()
        assert ref.startswith("exp ") and len(ref.splitlines()) == 1 + GV.N_EMBD
        assert open(dump).read() == ref


def test_fault_polarity_needs_a_pair():
    r = subprocess.run([sys.executable, os.path.join(HERE, "jc_loop.py"), "--sock", "/nonexistent", "--die", "A",
                        "--prompt", "/nonexistent", "--max-new", "1", "--synthetic", "--ids-out", "/nonexistent",
                        "--fault-polarity-at", "4"], capture_output=True, text=True, timeout=60)
    assert r.returncode == 2 and "--die2" in r.stderr


def soak_run(extra, seconds="3"):
    with tempfile.TemporaryDirectory(dir=SCRATCH) as work:
        GV.write_programs(work)
        b, sock = broker(work, ["--loop", "--loop-pair", "A,B"] + extra)
        try:
            with open(os.path.join(work, "p.txt"), "w") as f:
                f.write("1\n")
            r = subprocess.run([GV.RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2",
                                "--seq-reset", "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", GV.MAN_A,
                                "--max-new", "1", "--stop", "-1", "--ids-out", "open.txt", "--open-only",
                                "--jc-die2", "B", "--dtbl2", "b.dtbl", "--rel2", "b.rel", "--manifest2", GV.MAN_B],
                               cwd=work, capture_output=True, text=True, timeout=300)
            assert r.returncode == 0, r.stdout + r.stderr
            r = subprocess.run([sys.executable, os.path.join(HERE, "jc_link_soak.py"), "--sock", sock,
                                "--a", "A", "--b", "B", "--seconds", seconds], capture_output=True, text=True,
                               timeout=120)
            st = both(sock)
        finally:
            b.send_signal(signal.SIGTERM); b.wait(timeout=10)
    return r, st


def test_soak_accounting_on_the_model():
    """Plan Task 8 Step 2: on the model every resent frame is stale (SEQPOS_BAD), none
    corrupted, so the accounting closes exactly and the soak passes; both dies end stopped."""
    r, st = soak_run([])
    last = r.stdout.strip().splitlines()[-1]
    assert last.startswith("SOAK_PASS"), r.stdout + r.stderr
    assert int(last.split("frames=")[1].split()[0]) > 0
    assert st[0][0] == STATE_STOPPED and st[1][0] == STATE_STOPPED, st


def test_soak_accounting_slack_is_bounded_by_crc_fails():
    import jc_link_soak as S
    assert S.accounting_ok(100, 0, 100, 0)               # every resend stale, none corrupted
    assert not S.accounting_ok(100, 0, 99, 0)            # a lost verdict with no CRC failure
    assert S.accounting_ok(100, 2, 96, 0)                # two merges (two verdicts short)
    assert not S.accounting_ok(100, 2, 95, 0)            # three short with only two failures
    assert S.accounting_ok(100, 2, 100, 0)               # two splits (two verdicts over)
    assert not S.accounting_ok(100, 2, 101, 0)
    assert S.accounting_ok(100, 0, 0, 1)                 # a link-down: not checked
