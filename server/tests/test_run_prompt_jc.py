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
    def __init__(s, d, dies="A,B"):
        s.sock = os.path.join(d, "b.sock")
        s.log = os.path.join(d, "broker.log")
        s.p = subprocess.Popen([BROKER, s.sock, s.log, "--kv-maxpos", KV_MAXPOS, "--dies", dies],
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
