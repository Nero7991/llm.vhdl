"""server/llmvhdl_server.py --mode jc --jc-loop-host: loop mode, where a chat request runs
tools/jc/jc_loop.py on a remote host (the BC-250) over ssh instead of run_prompt here.

    make -C server run_prompt jc_sim_broker libqwen35chat.so
    python3 -m pytest -q server/tests/test_llmvhdl_server_jcloop.py

THE SETUP.  Two things are real (never faked): the startup --open-only call (jc_loop.py only
drives already-programmed dies, so the server streams the token programs once at startup
through the ordinary run_prompt --jc path) runs against jc_sim_broker, same as
test_llmvhdl_server_jc.py; and the ssh-script MECHANICS -- the bash script's heredoc, its pid
file, its fd-3 redirect, the Stop kill, the log-tail fetch -- run for real, just locally.

What is faked, and why: `--jc-loop-ssh-cmd` points at `fake_ssh.sh`, a one-line wrapper that
drops the ssh invocation's HOST argument and execs `bash -s` locally, so the "remote" bash
script in server/llmvhdl_server.py's jc_loop_script() runs on THIS machine against a local
directory standing in for the BC-250's. Inside that directory, `tools/jc/jc_loop.py` is a
small stand-in (FAKE_JC_LOOP below), not the real tools/jc/jc_loop.py: the real one's --mv4i
path raises DescError for any token id outside the embedding file's tiny M (tools/jc's own
test_jc_loop.py already covers the real jc_loop.py end to end, with --synthetic, against the
real sim broker's tok_loop model; that is NOT retested here). The stand-in still does the
three things this file is about: streams ids one at a time over --ids-stream, honours SIGTERM
(the real Stop mechanism, not a mock of it), and can be told to fail outright.

NO HARDWARE, no real ssh, no real broker socket, no BC-250. Scratch goes under
~/regress_scratch (never /tmp; AF_UNIX socket paths are limited to 108 bytes).
"""
import http.client
import json
import os
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
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
KV_MAXPOS = "16384"

_QTK_CANDIDATES = [
    os.environ.get("LLMVHDL_TEST_QTK", ""),
    os.path.join(REPO, "build_artifacts_tok", "qwen35_9b.qtk"),
    "/home/orencollaco/GitHub/llama.vhdl/build_artifacts_tok/qwen35_9b.qtk",
]
QTK_PATH = next((p for p in _QTK_CANDIDATES if p and os.path.isfile(p)), None)

pytestmark = pytest.mark.skipif(QTK_PATH is None, reason="no qwen35_9b.qtk found; set LLMVHDL_TEST_QTK")

# A stand-in for tools/jc/jc_loop.py (see the module docstring for why): streams --max-new
# fabricated ids, one per line, to --ids-stream, honouring SIGTERM the way the real jc_loop.py
# does (abort as soon as it is noticed, not mid-line), and failing outright on a sentinel file
# dropped next to the prompt, to test the error path without depending on a specific token id.
FAKE_JC_LOOP = '''\
import argparse, os, signal, sys, time

stopped = {"v": False}


def _h(signum, frame):
    stopped["v"] = True


signal.signal(signal.SIGTERM, _h)

ap = argparse.ArgumentParser()
ap.add_argument("--sock"); ap.add_argument("--die"); ap.add_argument("--die2")
ap.add_argument("--prompt", required=True)
ap.add_argument("--max-new", type=int, required=True)
ap.add_argument("--stop", type=int, default=-1)
ap.add_argument("--mv4i")
ap.add_argument("--ids-out", required=True)
ap.add_argument("--resend-max", type=int, default=3)
ap.add_argument("--ids-stream")
a = ap.parse_args()

workdir = os.path.dirname(os.path.abspath(a.prompt))
fault = os.path.join(workdir, "inject_fail")
if os.path.exists(fault):
    os.remove(fault)
    print("JCLOOP_FAIL simulated card fault")
    sys.exit(1)

stream = open(a.ids_stream, "w") if a.ids_stream else None
ids = []
reason = "MAX_NEW"
for i in range(a.max_new):
    if stopped["v"]:
        reason = "ABORT"
        break
    tid = 1000 + i
    ids.append(tid)
    if stream:
        stream.write("%d\\n" % tid)
        stream.flush()
    if tid == a.stop:
        reason = "STOP_ID"
        break
    time.sleep(0.2)
if stream:
    stream.close()
with open(a.ids_out, "w") as f:
    f.write("".join("%d\\n" % t for t in ids))
if reason == "ABORT":
    print("JCLOOP_FAIL aborted by signal ids=%d" % len(ids))
    sys.exit(1)
print("JCLOOP_DONE ids=%d reason=%s" % (len(ids), reason))
sys.exit(0)
'''

FAKE_SSH = """#!/bin/bash
# emulate `ssh user@host bash -s`: drop the host argument, exec the rest ("bash" "-s"),
# inheriting stdin/stdout/stderr -- exactly what a real ssh would relay.
shift
exec "$@"
"""


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
    """A fresh jc_sim_broker, dies A and B. No --loop: the startup --open-only call this
    server does in loop mode never touches tok_loop's register range."""

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
    d = tempfile.mkdtemp(prefix="llmjcloop", dir=base)
    yield d
    shutil.rmtree(d, ignore_errors=True)


class RawResp:
    """Copied from test_llmvhdl_server_jc.py: a POST over a plain socket, so a test can abort
    the connection mid-stream (http.client invalidates its socket on "Connection: close")."""

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
        s.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        s.sock.close()

    def close(s):
        s.sock.close()


def _read_sse(resp, want_done=True, max_lines=100000):
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


class LoopEnv:
    """A real jc_sim_broker (for the startup --open-only call) plus llmvhdl_server --mode jc
    --jc-loop-host, with ssh and the remote jc_loop.py both faked locally (module docstring)."""

    def __init__(s, work):
        s.work = work
        s.broker = Broker(work)
        run0 = os.path.join(work, "run0"); os.makedirs(run0)
        run1 = os.path.join(work, "run1"); os.makedirs(run1)
        _write_dtbl_rel(run0, "token", 4, 0x1000)
        _write_dtbl_rel(run1, "token", 3, 0x2000)

        s.loop_dir = os.path.join(work, "loopdir")
        os.makedirs(os.path.join(s.loop_dir, "tools", "jc"))
        with open(os.path.join(s.loop_dir, "tools", "jc", "jc_loop.py"), "w") as f:
            f.write(FAKE_JC_LOOP)

        s.fake_ssh = os.path.join(work, "fake_ssh.sh")
        with open(s.fake_ssh, "w") as f:
            f.write(FAKE_SSH)
        os.chmod(s.fake_ssh, os.stat(s.fake_ssh).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

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
               "--run-dir", s.run_dir,
               "--jc-loop-host", "user@bc250.example",
               "--jc-loop-dir", s.loop_dir,
               "--jc-loop-sock", "/nonexistent/broker.sock",
               "--jc-loop-emb", "/nonexistent/token_embd.weight.mv4i",
               "--jc-loop-python", sys.executable,
               "--jc-loop-ssh-cmd", s.fake_ssh]
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
        s.out.flush(); s.err.flush()
        raise AssertionError("llmvhdl_server --jc-loop-host did not become ready within %ss; see %s / %s"
                             % (timeout, s.out.name, s.err.name))

    def post_chat(s, max_tokens, content="hello", stream=True, timeout=60.0):
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


@pytest.fixture
def env(work):
    e = LoopEnv(work)
    yield e
    e.close()


def test_startup_runs_the_open_only_call_once(env):
    # The startup --open-only call is the thing that proves jc_loop mode never serves a
    # request against unprogrammed dies; its own log line is the evidence it ran.
    log = open(env.broker.log).read().splitlines()
    assert any(l == "A rd32 0xe000 1" for l in log), log[:5]
    assert any(l == "B rd32 0xe000 1" for l in log), log[:5]


def test_loop_mode_streams_ids_to_http_client(env):
    resp = env.post_chat(max_tokens=5)
    assert resp.status == 200, resp.read_all()
    payloads = _read_sse(resp)
    resp.close()
    assert payloads, "no SSE data frames"
    final = payloads[-1]
    assert final["usage"]["completion_tokens"] == 5, final
    assert final["choices"][0]["finish_reason"] == "length"
    # the ids came from the FAKE remote jc_loop.py (1000, 1001, ...), not run_prompt
    req_dir = env.newest_req_dir()
    facts = json.load(open(os.path.join(req_dir, "facts.json")))
    assert facts["n_ids"] == 5, facts
    assert not facts["termed"], facts


def test_stop_kills_the_remote_process_by_its_pid(env):
    resp = env.post_chat(max_tokens=100, content="stop me")
    assert resp.status == 200
    got, buf = 0, b""
    while got < 2:
        chunk = resp.read(1)
        if not chunk:
            break
        buf += chunk
        if buf.endswith(b"\n\n"):
            got += 1
            buf = b""
    resp.abort()

    t0 = time.time()
    facts = None
    while time.time() - t0 < 15:
        try:
            facts = json.load(open(os.path.join(env.newest_req_dir(), "facts.json")))
            if facts.get("termed"):
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    assert facts and facts.get("termed"), "the run was not stopped (facts: %s)" % facts
    assert 0 < facts["n_ids"] < 100, "stopped either immediately or not at all: %s" % facts

    # the kill reached the right process by its pid: the remote (local, faked) jc_loop.py
    # itself noticed SIGTERM and logged its own abort, proving the pid file round trip.
    pidfile = os.path.join(env.loop_dir, "ui_loop.pid")
    assert os.path.isfile(pidfile), "ui_loop.pid was never written"
    log = open(os.path.join(env.loop_dir, "ui_loop.log")).read()
    assert "aborted by signal" in log, log


def test_a_failing_remote_run_surfaces_as_a_card_error(env):
    # the sentinel: the NEXT invocation of the fake jc_loop.py fails outright, before it
    # streams any id, and with nothing to do with Stop.
    with open(os.path.join(env.loop_dir, "inject_fail"), "w") as f:
        f.write("1")
    resp = env.post_chat(max_tokens=5, stream=False)
    body = resp.read_all()
    resp.close()
    assert resp.status == 503, body
    err = json.loads(body)["error"]["message"]
    assert "Jungle Cat run failed" in err, err
    # the log tail (fetched over the second, post-run ssh call) is in the request's own dir
    req_dir = env.newest_req_dir()
    tail = open(os.path.join(req_dir, "ui_loop_log_tail.txt")).read()
    assert "simulated card fault" in tail, tail
