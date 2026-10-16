"""run_prompt --jc SOCK --jc-die D [--jc-die2 D2]: the Jungle Cat transport selected from the
command line, tested against a FAKE broker whose dies are the simulated seam.

    make -C server run_prompt jc_sim_broker && python3 -m pytest -q server/tests/test_run_prompt_jc.py

THE ORACLE.  server/tests/jc_sim_broker.c serves tools/jc/jc_broker.py's JSON-lines protocol
with one fk33_sim instance per die.  The same simulated card is driven twice: by run_prompt
with the sim transport directly, and by run_prompt --jc through fk33_transport_jc.c and the
broker.  The generated ids must be IDENTICAL (the sim's ids are plumbing, not inference, but
they depend on every GO, every window write and every position, so a dropped or misrouted
request changes them).  The broker's request log names the die of every request, so die
routing is checked directly: card 0 and card 1 get DIFFERENT descriptor programs here (4 and 3
descriptors), and the log shows which die received which.

NO HARDWARE: no /dev, no tools/jc/jc_broker.py, no coe.py, no BMC.  Scratch goes under
~/regress_scratch (AF_UNIX paths are limited to 108 bytes, and nothing goes under /tmp).
"""
import os, re, shutil, signal, subprocess, tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.dirname(HERE)
RUN_PROMPT = os.path.join(SERVER, "run_prompt")
BROKER = os.path.join(SERVER, "jc_sim_broker")
FIX = os.path.join(HERE, "fixtures")
MAN_A = os.path.join(FIX, "jc27b_die_a_hbm.json")
MAN_B = os.path.join(FIX, "jc27b_die_b_hbm.json")
KV_MAXPOS = "16384"   # the 27B card's C_MAXPOS (the manifests' card_c_maxpos)


@pytest.fixture(scope="module", autouse=True)
def built():
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.fixture
def work():
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    d = tempfile.mkdtemp(prefix="rpjc", dir=base)
    with open(os.path.join(d, "a.dtbl"), "w") as f:
        for k in range(4):
            for w in range(8):
                f.write("%016x\n" % (0x1000 * k + w + 1))
    with open(os.path.join(d, "a.rel"), "w") as f:
        for k in range(4):
            f.write(format(k + 1, "032b") + "\n")
    with open(os.path.join(d, "b.dtbl"), "w") as f:
        for k in range(3):
            for w in range(8):
                f.write("%016x\n" % (0x2000 * k + w + 7))
    with open(os.path.join(d, "b.rel"), "w") as f:
        for k in range(3):
            f.write(format(k + 9, "032b") + "\n")
    with open(os.path.join(d, "p.txt"), "w") as f:
        f.write("1 2 3\n")
    yield d
    shutil.rmtree(d, ignore_errors=True)


class Broker:
    def __init__(s, d, dies="A,B", extra=()):
        s.sock = os.path.join(d, "b.sock")
        s.log = os.path.join(d, "broker.log")
        s.p = subprocess.Popen([BROKER, s.sock, s.log, "--kv-maxpos", KV_MAXPOS, "--dies", dies]
                               + list(extra),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = s.p.stdout.readline()
        assert line.startswith("JCSIMBROKER_READY"), line + s.p.stderr.read()

    def stop(s):
        s.p.send_signal(signal.SIGTERM)
        s.p.wait(timeout=10)
        return open(s.log).read().splitlines()


def rp(d, *args):
    return subprocess.run([RUN_PROMPT] + list(args), capture_output=True, text=True, timeout=120,
                          cwd=d)


def pair_args(d, ids):
    return ["--prompt", "p.txt", "--v2", "--seq-reset",
            "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", MAN_A,
            "--dtbl2", "b.dtbl", "--rel2", "b.rel", "--manifest2", MAN_B,
            "--max-new", "5", "--stop", "-1", "--ids-out", ids]


def ids_of(path):
    return [l for l in open(path).read().splitlines() if not l.startswith("#")]


def wrn_counts(log, die):
    return [int(m.group(1)) for m in (re.match(r"^%s wrn 0x\w+ (\d+)$" % die, l) for l in log) if m]


def test_help_lists_the_jc_options():
    p = rp(SERVER, "--help")
    # hw/jc/host/jc_ctxtest.sh gates a real run on exactly this grep
    assert re.search(r"--jc[ ]", p.stderr + p.stdout), p.stderr
    assert "--jc-die " in p.stderr and "--jc-die2 " in p.stderr


@pytest.mark.parametrize("args,why", [
    (["--jc", "S"], "--jc needs --jc-die"),
    (["--jc-die", "A"], "--jc-die needs --jc"),
    (["--jc-die2", "B"], "--jc-die2 needs --jc"),
    (["--jc", "S", "--jc-die", "A", "--allow-hardware", "HOST"], "cannot be combined"),
    (["--jc", "S", "--jc-die", "A", "--dev", "/dev/xdma0"], "cannot be combined"),
    (["--jc", "S", "--jc-die", "A", "--dev2", "/dev/xdma1"], "cannot be combined"),
    (["--jc", "S", "--jc-die", "A", "--teeth-argmax", "3"], "cannot be combined"),
    (["--jc", "S", "--jc-die", "A", "--jc-die2", "B"], "--jc-die2 needs a second card"),
    (["--jc", "S", "--jc-die", "A", "--dtbl2", "b.dtbl", "--rel2", "b.rel",
      "--manifest2", MAN_B], "a second card on --jc needs --jc-die2"),
    (["--jc", "S", "--jc-die", "A", "--jc-die2", "A", "--dtbl2", "b.dtbl", "--rel2", "b.rel",
      "--manifest2", MAN_B], "must name different dies"),
    (["--jc", "S", "--jc-die", "A"], "--jc needs --v2"),
    (["--jc", "S", "--jc-die", "A", "--dump-xout2", "b.x"], "--dump-xout2 needs a second card"),
])
def test_refusals_happen_before_any_connection(work, args, why):
    base = ["--prompt", "p.txt"]
    if why != "--jc needs --v2":
        base += ["--v2", "--dtbl", "a.dtbl", "--rel", "a.rel"]
    p = rp(work, *(base + args))
    assert p.returncode == 2, (args, p.returncode, p.stdout, p.stderr)
    assert why in p.stderr, (args, p.stderr)
    assert "fk33_transport_jc:" not in p.stderr   # the transport never opened (it prefixes this)


def test_pair_over_the_broker_matches_the_sim_and_routes_dies(work):
    ref = rp(work, *(pair_args(work, "sim.ids") + ["--sim-kv-maxpos", KV_MAXPOS]))
    assert ref.returncode == 0, ref.stdout + ref.stderr
    b = Broker(work)
    p = rp(work, *(["--jc", b.sock, "--jc-die", "A", "--jc-die2", "B"] + pair_args(work, "jc.ids")))
    log = b.stop()
    assert p.returncode == 0, p.stdout + p.stderr
    assert re.search(r"^transport  JC broker %s die A$" % re.escape(b.sock), p.stdout, re.M), p.stdout
    assert re.search(r"^transport2 JC broker %s die B$" % re.escape(b.sock), p.stdout, re.M), p.stdout
    assert re.search(r"^seq-reset  seam AND engine positions cleared", p.stdout, re.M), p.stdout
    assert re.search(r"^prefill +3 ids, pos 3, first argmax \d+", p.stdout, re.M), p.stdout
    assert ids_of(os.path.join(work, "jc.ids")) == ids_of(os.path.join(work, "sim.ids"))
    assert len(ids_of(os.path.join(work, "jc.ids"))) == 5
    # the first request of the run is card 0's identity read, on die A
    assert log[0] == "A rd32 0xe000 1", log[:3]
    # card 0's program (4 descriptors = 64 halves) went to A, card 1's (3 = 48) to B
    assert 64 in wrn_counts(log, "A") and 48 not in wrn_counts(log, "A")
    assert 48 in wrn_counts(log, "B") and 64 not in wrn_counts(log, "B")
    assert not [l for l in log if l.startswith("?") or " unknown " in l], log
    # the v2 flow over the JC transport never needs an HBM write (mem_write is -EPERM)
    assert "EPERM" not in p.stderr and "mem_write" not in p.stderr


def test_swapped_dies_swap_the_programs(work):
    ref = rp(work, *(pair_args(work, "sim.ids") + ["--sim-kv-maxpos", KV_MAXPOS]))
    assert ref.returncode == 0
    b = Broker(work)
    p = rp(work, *(["--jc", b.sock, "--jc-die", "B", "--jc-die2", "A"] + pair_args(work, "jc.ids")))
    log = b.stop()
    assert p.returncode == 0, p.stdout + p.stderr
    assert log[0] == "B rd32 0xe000 1", log[:3]
    assert 64 in wrn_counts(log, "B") and 48 in wrn_counts(log, "A")
    assert ids_of(os.path.join(work, "jc.ids")) == ids_of(os.path.join(work, "sim.ids"))


def test_single_die(work):
    args = ["--prompt", "p.txt", "--v2", "--seq-reset", "--dtbl", "a.dtbl", "--rel", "a.rel",
            "--manifest", MAN_B, "--max-new", "4", "--stop", "-1"]
    ref = rp(work, *(args + ["--ids-out", "sim.ids", "--sim-kv-maxpos", KV_MAXPOS]))
    assert ref.returncode == 0, ref.stdout + ref.stderr
    b = Broker(work)
    p = rp(work, *(["--jc", b.sock, "--jc-die", "B"] + args + ["--ids-out", "jc.ids"]))
    log = b.stop()
    assert p.returncode == 0, p.stdout + p.stderr
    assert {l.split()[0] for l in log if not l.startswith("-")} == {"B"}, log
    assert ids_of(os.path.join(work, "jc.ids")) == ids_of(os.path.join(work, "sim.ids"))


def test_a_die_the_broker_does_not_have_fails_the_open(work):
    b = Broker(work, dies="A")
    p = rp(work, *(["--jc", b.sock, "--jc-die", "A", "--jc-die2", "B"] + pair_args(work, "jc.ids")))
    log = b.stop()
    assert p.returncode != 0, p.stdout
    assert re.search(r"pl_open refused card 1", p.stderr), p.stderr
    assert any(l.startswith("? refused") and '"die":"B"' in l for l in log), log


def test_dump_xout2_reads_the_second_die(work):
    # --dump-xout reads card 0 (the hop row); --dump-xout2 reads card 1, the LAST block's R_X,
    # which is the row the CPU reference's final residual is compared against
    b = Broker(work)
    p = rp(work, *(["--jc", b.sock, "--jc-die", "A", "--jc-die2", "B"] + pair_args(work, "jc.ids")
                   + ["--dump-xout", "a.x", "--dump-xout2", "b.x"]))
    log = b.stop()
    assert p.returncode == 0, p.stdout + p.stderr
    assert re.search(r"^xout  +R_X after the last GO: exp -?\d+, \d+ mantissas -> a\.x$", p.stdout, re.M)
    assert re.search(r"^xout2 +card 1 R_X after the last GO: exp -?\d+, \d+ mantissas -> b\.x$",
                     p.stdout, re.M), p.stdout
    for f in ("a.x", "b.x"):
        t = open(os.path.join(work, f)).read().split()
        assert t[0] == "exp" and len(t) > 3, (f, t[:4])
    # the XEXP_OUT read (seam 0xA4) is the last thing each die is asked, after its last GO
    xe = [l.split()[0] for l in log if re.match(r"^[AB] rd32 0xe0a4 ", l)]
    assert xe[-2:] == ["A", "B"], log[-20:]


# ---- 2026-10-09 silicon: a read the broker cannot confirm after a BMC link drop
# (WindowUnknown, op 3 at 0xe060, "verdict NOTFAILED") must not end the run. Every seam read
# except WIN_DATA is side-effect free, so it is re-read; a WIN_DATA read advances WIN_ADDR
# (rtl/fk33_seam.vhd READ CHANNEL), so it is retried only after WIN_SEL/WIN_ADDR are written
# again. `ran` is the case where the lost read DID advance WIN_ADDR: a retry without the
# re-seek would skip an element there. (Since 2026-10-16 the WIN_DATA reads are one rdn per
# window, so their fault cases are in the rdn section below.)

PL_RD_RETRIES = 2      # server/pl_backend.c


def _faulted_pair(work, spec):
    ref = rp(work, *(pair_args(work, "sim.ids") + ["--sim-kv-maxpos", KV_MAXPOS]))
    assert ref.returncode == 0, ref.stdout + ref.stderr
    b = Broker(work, extra=["--fail-rd", spec])
    p = rp(work, *(["--jc", b.sock, "--jc-die", "A", "--jc-die2", "B"] + pair_args(work, "jc.ids")))
    return ref, p, b.stop()


def test_an_unconfirmed_status_read_is_retried(work):
    ref, p, log = _faulted_pair(work, "B:0xe018:2:ran")
    assert p.returncode == 0, p.stdout + p.stderr
    assert ids_of(os.path.join(work, "jc.ids")) == ids_of(os.path.join(work, "sim.ids"))
    k = log.index("B rd32 0xe018 1 FAILED ran")
    assert log[k + 1] == "B rd32 0xe018 1", log[k - 2:k + 4]


def test_a_read_that_keeps_failing_is_given_up_after_the_bound(work):
    # was the WIN_DATA rd32 at 0xe060 until 2026-10-16; WIN_DATA is now read by rdn (below), so
    # the plain-register bound is held on STATUS instead
    ref, p, log = _faulted_pair(work, "B:0xe018:2:lost:100")
    assert p.returncode != 0, p.stdout
    assert len([l for l in log if l.endswith("FAILED lost")]) == 1 + PL_RD_RETRIES, log[-12:]


# ---- 2026-10-16: the hop reads R_X with ONE bulk `rdn` per window, not n_embd rd32s.
# Silicon 2026-10-09/10: a 23-position 27B prefill spent 1235 s of 1255 s in "hop read R_X",
# one CoE round trip per WIN_DATA word. The broker already serves
# {"op":"rdn","off":WIN_DATA,"fix":true,"n":K}; WIN_DATA auto-increments WIN_ADDR on every read
# (rtl/fk33_seam.vhd READ CHANNEL), so a fixed-offset rdn is exactly the old loop.
#
# The oracle is the same simulated card driven directly: ids AND both --dump-xout files must be
# byte-identical to the sim reference.

N_EMBD = 4096          # fk33_sim_opts_default's n_embd: one XOUT window
WIN_DATA = "0xe060"    # FK33_SEAM_BASE + FK33_SEAM_WIN_DATA


def _pair_with_dumps(work, extra_broker=()):
    ref = rp(work, *(pair_args(work, "sim.ids") + ["--sim-kv-maxpos", KV_MAXPOS,
                                                   "--dump-xout", "sim.a.x",
                                                   "--dump-xout2", "sim.b.x"]))
    assert ref.returncode == 0, ref.stdout + ref.stderr
    b = Broker(work, extra=list(extra_broker))
    p = rp(work, *(["--jc", b.sock, "--jc-die", "A", "--jc-die2", "B"] + pair_args(work, "jc.ids")
                   + ["--dump-xout", "a.x", "--dump-xout2", "b.x"]))
    return ref, p, b.stop()


def _same_as_sim(work):
    assert ids_of(os.path.join(work, "jc.ids")) == ids_of(os.path.join(work, "sim.ids"))
    for jc, sim in (("a.x", "sim.a.x"), ("b.x", "sim.b.x")):
        a = open(os.path.join(work, jc), "rb").read()
        r = open(os.path.join(work, sim), "rb").read()
        assert a == r, (jc, len(a), len(r))
        assert len(a.split()) == 2 + N_EMBD, (jc, a[:40])


def _rdns(log, die):
    return [l for l in log if re.match(r"^%s rdn %s " % (die, WIN_DATA), l)]


def test_the_hop_reads_r_x_with_one_rdn_per_window(work):
    ref, p, log = _pair_with_dumps(work)
    assert p.returncode == 0, p.stdout + p.stderr
    _same_as_sim(work)
    hops = int(re.search(r"^hop +(\d+) hops:", p.stdout, re.M).group(1))
    assert hops >= 1, p.stdout
    # not one WIN_DATA word goes out as its own rd32 any more
    assert not [l for l in log if re.match(r"^[AB] rd32 %s " % WIN_DATA, l)], \
        [l for l in log if WIN_DATA in l][:5]
    # one rdn of the whole window per hop on card 0, plus --dump-xout; one on card 1 (--dump-xout2)
    assert _rdns(log, "A") == ["A rdn %s %d" % (WIN_DATA, N_EMBD)] * (hops + 1), _rdns(log, "A")
    assert _rdns(log, "B") == ["B rdn %s %d" % (WIN_DATA, N_EMBD)], _rdns(log, "B")
    # every rdn is preceded by the absolute seek: WIN_SEL then WIN_ADDR
    for k, l in enumerate(log):
        if " rdn " in l:
            d = l.split()[0]
            assert log[k - 2:k] == ["%s wr32 0xe058 1" % d, "%s wr32 0xe05c 1" % d], log[k - 3:k + 1]


# Fault injection on the rdn itself. done_items is the frames (496 items, jc_ctl.MAX_ITEMS)
# before the failing one; `ran` means the failing frame executed too. In every case below except
# (lost, 0) WIN_ADDR has MOVED, so a retry without the re-seek reads a shifted window: those
# cases are the teeth for the re-seek (the no-re-seek mutant must fail them).
@pytest.mark.parametrize("mode,at", [("lost", 0), ("ran", 0), ("lost", 1000), ("ran", 3000)])
def test_an_unconfirmed_rdn_is_reseeked_and_reissued(work, mode, at):
    ref, p, log = _pair_with_dumps(work, ["--fail-rdn", "A:%s:2:%s:%d" % (WIN_DATA, mode, at)])
    assert p.returncode == 0, p.stdout + p.stderr
    _same_as_sim(work)
    k = [i for i, l in enumerate(log) if " FAILED " in l]
    assert len(k) == 1, log
    k = k[0]
    assert log[k].startswith("A rdn %s %d FAILED %s done=%d " % (WIN_DATA, N_EMBD, mode,
                                                               at // 496 * 496)), log[k]
    # the retry re-selects XOUT and re-seeks WIN_ADDR, then re-issues the WHOLE window
    assert log[k + 1:k + 4] == ["A wr32 0xe058 1", "A wr32 0xe05c 1",
                                "A rdn %s %d" % (WIN_DATA, N_EMBD)], log[k - 2:k + 6]
    assert "WindowUnknown: injected" in p.stderr
    assert "done_items=%d" % (at // 496 * 496) in p.stderr, p.stderr
    assert re.search(r"retrying \(1 of %d\)" % PL_RD_RETRIES, p.stderr), p.stderr


def test_an_rdn_that_keeps_failing_is_given_up_after_the_bound(work):
    ref, p, log = _pair_with_dumps(work, ["--fail-rdn", "A:%s:1:lost:0:100" % WIN_DATA])
    assert p.returncode != 0, p.stdout
    assert len([l for l in log if " FAILED lost" in l]) == 1 + PL_RD_RETRIES, log[-12:]
    # writes are never retried: exactly one re-seek pair per retry, nothing more
    k = [i for i, l in enumerate(log) if " FAILED " in l]
    for a, b in zip(k, k[1:]):
        assert log[a + 1:b] == ["A wr32 0xe058 1", "A wr32 0xe05c 1"], log[a:b + 1]
