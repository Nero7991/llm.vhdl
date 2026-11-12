"""server/llmvhdl_server.py --mode jc, tested against the FAKE broker only
(server/tests/jc_sim_broker.c), never the real one.

    make -C server run_prompt jc_sim_broker libqwen35chat.so
    python3 -m pytest -q server/tests/test_llmvhdl_server_jc.py

THE SETUP.  jc_sim_broker serves tools/jc/jc_broker.py's protocol with one
simulated die per --dies entry, exactly as server/tests/test_run_prompt_jc.py
drives it.  llmvhdl_server.py --mode jc is started as a real subprocess
against that broker's socket, on a free localhost port, and driven over HTTP
the way the UI drives it: POST /v1/chat/completions with "stream": true.

NO HARDWARE: no /dev, no tools/jc/jc_broker.py, no coe.py, no BMC, and the
real broker socket (in use elsewhere) is never touched.  Scratch goes under
~/regress_scratch (never /tmp).
"""
import http.client
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.dirname(HERE)
REPO = os.path.dirname(SERVER)
RUN_PROMPT = os.path.join(SERVER, "run_prompt")
BROKER_BIN = os.path.join(SERVER, "jc_sim_broker")
LIB = os.path.join(SERVER, "libqwen35chat.so")
LLMVHDL = os.path.join(SERVER, "llmvhdl_server.py")
UI_DIR = os.path.join(REPO, "ui", "dist")
FIX = os.path.join(HERE, "fixtures")
MAN_A = os.path.join(FIX, "jc27b_die_a_hbm.json")
MAN_B = os.path.join(FIX, "jc27b_die_b_hbm.json")
KV_MAXPOS = "16384"   # the 27B card's C_MAXPOS (the manifests' card_c_maxpos)

# The .qtk is a ~9 MB artefact, gitignored, not present in every worktree.
# This one and the FK33 repo's copy are the same file (checked 2026-10-09:
# the 27B GGUF's tokens and merges hash identical to the 9B's).
_QTK_CANDIDATES = [
    os.environ.get("LLMVHDL_TEST_QTK", ""),
    os.path.join(REPO, "build_artifacts_tok", "qwen35_9b.qtk"),
    "/home/orencollaco/GitHub/llama.vhdl/build_artifacts_tok/qwen35_9b.qtk",
]
QTK_PATH = next((p for p in _QTK_CANDIDATES if p and os.path.isfile(p)), None)

pytestmark = pytest.mark.skipif(QTK_PATH is None, reason="no qwen35_9b.qtk found; set LLMVHDL_TEST_QTK")


@pytest.fixture(scope="module", autouse=True)
def built():
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker", "libqwen35chat.so"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def _free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Broker:
    """A fresh jc_sim_broker, dies A and B, matching test_run_prompt_jc.py."""

    def __init__(s, d):
        s.sock = os.path.join(d, "b.sock")
        s.log = os.path.join(d, "broker.log")
        s.p = subprocess.Popen([BROKER_BIN, s.sock, s.log, "--kv-maxpos", KV_MAXPOS, "--dies", "A,B"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = s.p.stdout.readline()
        assert line.startswith("JCSIMBROKER_READY"), line + s.p.stderr.read()

    def stop(s):
        s.p.send_signal(signal.SIGTERM)
        s.p.wait(timeout=10)
        return open(s.log).read().splitlines()


def _write_dtbl_rel(d, name, n_desc, base):
    with open(os.path.join(d, name + ".dtbl"), "w") as f:
        for k in range(n_desc):
            for w in range(8):
                f.write("%016x\n" % (base * k + w + 1))
    with open(os.path.join(d, name + ".rel"), "w") as f:
        for k in range(n_desc):
            f.write(format(k + 1, "032b") + "\n")


@pytest.fixture
def work():
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    d = tempfile.mkdtemp(prefix="llmjc", dir=base)
    yield d
    shutil.rmtree(d, ignore_errors=True)


class RawResp:
    """A POST issued and read over a plain socket: status, then .read(n)
    streams the body (we always send "Connection: close", so EOF ends it),
    and .sock is the live socket for a test that wants to abort it."""

    def __init__(s, port, req, timeout):
        s.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        s.sock.sendall(req)
        s._buf = b""
        while b"\r\n\r\n" not in s._buf:
            chunk = s.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed before headers arrived")
            s._buf += chunk
        head, s._buf = s._buf.split(b"\r\n\r\n", 1)
        s.status = int(head.split(b"\r\n", 1)[0].split(b" ", 2)[1])

    def read(s, n):
        if s._buf:
            out, s._buf = s._buf[:n], s._buf[n:]
            return out
        try:
            return s.sock.recv(n)
        except OSError:
            return b""

    def read_all(s):
        out = [s._buf]
        s._buf = b""
        while True:
            chunk = s.read(65536)
            if not chunk:
                break
            out.append(chunk)
        return b"".join(out)

    def abort(s):
        """Force a RST on close, so the server's next write sees it (a plain
        close() sends only a FIN, which a server writing fast, small chunks
        on loopback may not notice for a long time -- MEASURED)."""
        s.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        s.sock.close()

    def close(s):
        s.sock.close()


class Env:
    """A running jc_sim_broker plus a llmvhdl_server --mode jc pointed at it."""

    def __init__(s, work):
        s.work = work
        s.broker = Broker(work)
        run0 = os.path.join(work, "run0"); os.makedirs(run0)
        run1 = os.path.join(work, "run1"); os.makedirs(run1)
        # card 0: 4 descriptors (64 halves); card 1: 3 (48 halves) -- the same
        # shapes test_run_prompt_jc.py uses, so the fixture manifests apply.
        _write_dtbl_rel(run0, "token", 4, 0x1000)
        _write_dtbl_rel(run1, "token", 3, 0x2000)
        s.run_dir = os.path.join(work, "server_runs")
        s.port = _free_port()
        s.out = open(os.path.join(work, "server.out"), "wb")
        s.err = open(os.path.join(work, "server.err"), "wb")
        cmd = [sys.executable, LLMVHDL, "--host", "127.0.0.1", "--port", str(s.port),
               "--mode", "jc", "--jc-sock", s.broker.sock,
               "--jc-run0", run0, "--jc-run1", run1,
               "--jc-man0", MAN_A, "--jc-man1", MAN_B,
               "--jc-die0", "A", "--jc-die1", "B",
               "--qtk", QTK_PATH, "--lib", LIB, "--ui-dir", UI_DIR,
               "--run-dir", s.run_dir]
        s.proc = subprocess.Popen(cmd, cwd=REPO, stdout=s.out, stderr=s.err, start_new_session=True)
        s._wait_ready()

    def _wait_ready(s, timeout=20.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if s.proc.poll() is not None:
                s.out.flush(); s.err.flush()
                raise AssertionError("llmvhdl_server exited early (rc %s); see %s / %s"
                                     % (s.proc.returncode, s.out.name, s.err.name))
            try:
                c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=1.0)
                c.request("GET", "/health")
                r = c.getresponse()
                ok = r.status == 200
                r.read()
                c.close()
                if ok:
                    return
            except (ConnectionRefusedError, OSError):
                pass
            time.sleep(0.1)
        raise AssertionError("llmvhdl_server --mode jc did not become ready within %ss" % timeout)

    def post_chat(s, max_tokens, content="hello", stream=True, timeout=60.0):
        # A raw socket, not http.client: http.client's connection object
        # closes (and invalidates) its own socket the instant getresponse()
        # sees "Connection: close" -- true of every response this server
        # sends -- which leaves no live socket for a test that wants to
        # force-abort the connection (SO_LINGER) partway through a stream.
        body = json.dumps({"model": "x", "stream": stream, "max_tokens": max_tokens,
                           "messages": [{"role": "user", "content": content}]}).encode()
        req = (b"POST /v1/chat/completions HTTP/1.1\r\n"
               b"Host: 127.0.0.1\r\n"
               b"Content-Type: application/json\r\n"
               b"Content-Length: " + str(len(body)).encode() + b"\r\n"
               b"Connection: close\r\n\r\n") + body
        return RawResp(s.port, req, timeout)

    def newest_req_dir(s):
        reqs = sorted(d for d in os.listdir(s.run_dir) if d.startswith("req_"))
        assert reqs, "no request directories under %s" % s.run_dir
        return os.path.join(s.run_dir, reqs[-1])

    def close(s):
        try:
            os.killpg(s.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            s.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(s.proc.pid, signal.SIGKILL)
            s.proc.wait(timeout=10)
        s.out.close(); s.err.close()
        s.broker.stop()


def _read_sse(resp, want_done=True, max_lines=100000):
    """Read an SSE response to [DONE] (or EOF).  Returns the list of parsed
    `data: {...}` payloads, [DONE] excluded."""
    payloads = []
    buf = b""
    n = 0
    while n < max_lines:
        chunk = resp.read(4096)
        if not chunk:
            break
        buf += chunk
        while b"\n\n" in buf:
            frame, buf = buf.split(b"\n\n", 1)
            n += 1
            if not frame.startswith(b"data: "):
                continue
            payload = frame[len(b"data: "):]
            if payload == b"[DONE]":
                return payloads
            payloads.append(json.loads(payload))
    if want_done:
        raise AssertionError("SSE stream ended without [DONE] (%d frames)" % len(payloads))
    return payloads


@pytest.fixture
def env(work):
    e = Env(work)
    yield e
    e.close()


def test_chat_completion_streams_tokens_and_routes_both_dies(env):
    resp = env.post_chat(max_tokens=6)
    assert resp.status == 200, resp.read_all()
    payloads = _read_sse(resp)
    resp.close()
    assert payloads, "no SSE data frames"
    final = payloads[-1]
    assert final["usage"]["completion_tokens"] >= 1, final
    assert final["choices"][0]["finish_reason"] in ("length", "stop")
    # the request actually drove BOTH dies through the broker, on A and B
    log = env.broker.log
    lines = open(log).read().splitlines()
    assert any(l.startswith("A ") for l in lines), lines[:5]
    assert any(l.startswith("B ") for l in lines), lines[:5]
    # card 0's program (4 descriptors = 64 halves) went to die A, card 1's (3 = 48) to die B
    wrn_a = [int(m.group(1)) for m in (re.match(r"^A wrn 0x\w+ (\d+)$", l) for l in lines) if m]
    wrn_b = [int(m.group(1)) for m in (re.match(r"^B wrn 0x\w+ (\d+)$", l) for l in lines) if m]
    assert 64 in wrn_a and 64 not in wrn_b, lines
    assert 48 in wrn_b and 48 not in wrn_a, lines


def test_second_concurrent_request_is_queued_not_refused(env):
    # NOTE on what req2 is allowed to do: jc_sim_broker's dies persist for the
    # broker's whole life, and fk33_sim.c's SEQ_RESET does not clear the
    # host-written SEQ_POS scratch register (only --dies state from a FRESH
    # broker reads 0/0 after --seq-reset); a SECOND --seq-reset against the
    # SAME simulated die therefore fails pl_seq_reset's own post-reset check
    # (rc -5), a known simulator gap relative to the 2026-11-12 silicon
    # finding that --seq-reset masks stale state there.  So req2 here may
    # legitimately come back 503 for THAT reason.  What this test checks is
    # the thing in scope: the lock queues req2 behind req1 rather than
    # running them concurrently against the one-client broker (which the
    # broker's own single accept-at-a-time loop would otherwise corrupt).
    # req1 is deliberately long (the sim does ~1.5k tokens/s, so 40 tokens is
    # over far too fast to reliably still be "running" by the time a second
    # thread gets scheduled -- MEASURED): long enough that req2, started
    # shortly after, is certain to still find it in flight.
    results = {}

    def run1():
        r = env.post_chat(max_tokens=2000, content="first")
        body = r.read_all()
        r.close()
        results["req1"] = (r.status, body)

    th = threading.Thread(target=run1)
    th.start()
    time.sleep(0.05)   # let req1 take the lock and start its run
    assert th.is_alive(), "req1 (2000 tokens) already finished; not a real overlap -- raise max_tokens"

    r2 = env.post_chat(max_tokens=4, content="second", stream=False)
    body2 = r2.read_all()
    r2.close()
    # THE SERIALIZATION PROOF: req2 holds the SAME lock req1 holds for its
    # whole run, so req2's response cannot land while req1 is still running.
    # If it did, the two requests ran concurrently against the one-client
    # broker -- the bug this test exists to catch.
    assert not th.is_alive(), "req1 was still running when req2's response landed: not serialized"
    th.join(timeout=60)
    assert "req1" in results, "req1 did not finish"
    req1_status, req1_body = results["req1"]
    assert req1_status == 200, req1_body

    if r2.status != 200:
        assert r2.status == 503 and b"seq-reset" in body2, (r2.status, body2)

    # and the two sessions never interleaved on the broker: req2's run_prompt
    # only opens its connection (the identity read on die A) once req1's own
    # session, with its run of decode GOs, is long done -- the two "A rd32
    # 0xe000 1" identity reads are far apart, not back to back.
    log = open(env.broker.log).read().splitlines()
    opens = [i for i, l in enumerate(log) if l == "A rd32 0xe000 1"]
    assert len(opens) == 2, log
    assert opens[1] - opens[0] > 20, "req1's session looks too short; log: %r" % log


def test_stop_ends_the_run_and_leaves_the_broker_usable(env):
    resp = env.post_chat(max_tokens=2000, content="stop me")
    assert resp.status == 200
    # read a few frames so generation has actually started, then abandon it
    got = 0
    buf = b""
    while got < 3:
        chunk = resp.read(1)
        if not chunk:
            break
        buf += chunk
        if buf.endswith(b"\n\n"):
            got += 1
            buf = b""
    resp.abort()   # the UI's Stop: the client goes away mid-stream, forcibly

    t0 = time.time()
    facts = None
    while time.time() - t0 < 15:
        try:
            with open(os.path.join(env.newest_req_dir(), "facts.json")) as f:
                facts = json.load(f)
            if facts.get("termed"):
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    assert facts and facts.get("termed"), "the run was not stopped (facts: %s)" % facts

    # The broker must still be USABLE: a fresh request gets a clean, timely
    # answer from it (not a hang, not a broken connection) rather than the
    # broker wedging because the previous session was cut off mid-run.  It
    # may still be the known jc_sim_broker gap on a SECOND --seq-reset (see
    # the concurrency test above) -- that is a simulator limitation, not a
    # broker-usability one, so a clean 503 naming seq-reset also passes.
    resp2 = env.post_chat(max_tokens=3, content="after stop", stream=False)
    body2 = resp2.read_all()
    resp2.close()
    if resp2.status != 200:
        assert resp2.status == 503 and b"seq-reset" in body2, (resp2.status, body2)
    # and the broker itself is still answering identity reads cleanly
    log = open(env.broker.log).read().splitlines()
    assert sum(1 for l in log if l == "A rd32 0xe000 1") == 2, log
