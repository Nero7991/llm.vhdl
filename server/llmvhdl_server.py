#!/usr/bin/env python3
"""llm.vhdl web server: the llama.cpp web UI in front of the FK33 cards, or the
Jungle Cat.

    python3 server/llmvhdl_server.py                 # two FK33 cards, port 8000
    python3 server/llmvhdl_server.py --mode single   # one FK33 card (FK33_USER picks it)
    python3 server/llmvhdl_server.py --mode jc --jc-sock /path/to/broker.sock \\
        --jc-run0 RUN0 --jc-run1 RUN1 --jc-man0 MAN0 --jc-man1 MAN1 \\
        --jc-emb /mnt/storage/llama-models/qwen38-27b-mv4i/token_embd.weight.mv4i \\
        --qtk build_artifacts_tok/qwen35_9b.qtk    # the Jungle Cat (2 dies) through its broker

Then open https://llmvhdl.example.com/ on the LAN (Caddy, LAN-fenced, set up by
~/GitHub/DevOps/add-llmvhdl-vhost.sh 2026-09-24), or http://127.0.0.1:8000/ here.

WHAT IT IS.  A standard-library HTTP server that speaks the subset of the
llama.cpp server API the web UI in `ui/` uses (`/props`, `/v1/models`,
`/v1/chat/completions` with SSE streaming, `/health`) and answers every chat
request by running the silicon path that is already validated.  Two of the
three modes (`pair`, `single`) do this through `hw/fk33/host/fk33_chat2.sh` /
`fk33_chat.sh`, unchanged, with the conversation passed as token ids
(`FK33_PROMPT_IDS`); the third (`jc`) runs `server/run_prompt` directly with
its `--jc` options against the Jungle Cat broker, since the JC needs no
per-request card prep (see `--mode jc` below).  Every mode streams each
generated id back through `run_prompt --ids-stream`.

`--mode jc`.  Two dies reached through `tools/jc/jc_broker.py` over a Unix
socket, which serves ONE client: the existing one-request-at-a-time lock
covers it, same as the two FK33 cards.  Options:
  --jc-sock PATH     the broker's Unix socket (required)
  --jc-run0 / --jc-run1   token program dirs (token.dtbl, token.rel) for
                     card 0 / card 1 (required)
  --jc-man0 / --jc-man1   the manifests of the images resident on card 0's /
                     card 1's die (required)
  --jc-emb PATH      the token embedding .mv4i; omitting it falls back to
                     run_prompt's synthetic embedding (a stderr warning, not
                     a model of anything) -- pass it for a real run
  --jc-die0 / --jc-die1   the dies on the broker's chain, default A / B
The model on the JC is 27B (Qwen3.8-27B); the tokenizer is the 9B .qtk
(identical tokens and template across the family, checked 2026-10-09), so
--qtk needs no change from the FK33 default.  The JC's C_MAXPOS is 16384
(the manifests' `hbm.card_c_maxpos`); --n-ctx defaults to that in jc mode
unless given explicitly.  GDN state does NOT need re-zeroing between
requests on the JC (MEASURED on silicon 2026-11-12: --seq-reset masks stale
state), so jc mode runs no prep step before a request, unlike fk33_chat2.sh.

`--jc-loop-host USER@HOST` (jc mode only) turns on LOOP MODE: a chat request
runs `tools/jc/jc_loop.py` on that host (the BC-250, reached through the
same broker) instead of `run_prompt` here, over `ssh -o BatchMode=yes HOST
bash -s`. jc_loop drives the on-fabric token loop at the card's own speed
(about 2x faster than the host round trips run_prompt makes), but it never
touches the token programs itself, so at startup this server runs the usual
`run_prompt --jc ... --open-only` once to stream them; a failure there fails
startup. `--jc-loop-dir` is the remote directory holding jc_loop.py, its
siblings, the embedding file and the broker socket; `--jc-loop-sock` and
`--jc-loop-emb` are that broker's socket and the embedding file's paths ON
THE REMOTE HOST; `--jc-loop-python` (default python3) is the remote
interpreter. Stop runs a second, short ssh call that kills jc_loop's pid by
reading it back from /proc (never pkill/pgrep).

The chat template and the tokenizer are NOT reimplemented here: they are the
verified C files (`qwen35_chat.c`, `qwen35_tok.c`) loaded through ctypes from
`server/libqwen35chat.so` (`make -C server libqwen35chat.so`).

WHAT IT IS NOT, and the UI is told so through /props and /v1/models:
  - Greedy only.  The card returns its running argmax, not logits, so
    temperature, top_p and the rest are accepted and IGNORED.
  - One request at a time.  The cards (or the broker) hold one sequence; a
    second request waits for the first.
  - No prompt cache.  Every turn re-prefills the whole conversation from
    position 0 (about 0.17 s per token on the pair, MEASURED 2026-09-24), because
    the GDN layers keep a recurrent state that cannot be rewound and the
    template renders a past assistant turn differently from how it was
    generated, so an append-only prefix match would not hold.
  - Text only: images, audio and tools are refused.

Stop in the UI sends SIGTERM to run_prompt, which ends the decode after the
GO in flight (never inside one).  A card that reports a fault turns into an
HTTP error before the first token, or a visible note after it; a wedged card
needs a reload (`hw/fk33/host/fk33_reload.sh`), which this server never does.

Opens /dev/xdma* through the chat scripts (pair/single modes) or the broker
socket (jc mode): a human or the main session runs it, never a subagent.
"""
import argparse
import codecs
import ctypes
import json
import mimetypes
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QTK_DEFAULT = os.path.join(REPO, "build_artifacts_tok", "qwen35_9b.qtk")
LIB_DEFAULT = os.path.join(REPO, "server", "libqwen35chat.so")
UI_DEFAULT = os.path.join(REPO, "ui", "dist")
RUN_DEFAULT = "/mnt/storage/fk33_builds/llmvhdl_server"   # never /tmp: CLAUDE.md
RUN_PROMPT = os.path.join(REPO, "server", "run_prompt")
CHAT = {"pair": os.path.join(REPO, "hw", "fk33", "host", "fk33_chat2.sh"),
        "single": os.path.join(REPO, "hw", "fk33", "host", "fk33_chat.sh")}
JC_N_CTX_DEFAULT = 16384   # the Jungle Cat's C_MAXPOS (manifests' hbm.card_c_maxpos)

ROLE = {"system": 0, "user": 1, "assistant": 2, "tool": 3}


# --------------------------------------------------------------------------
# The verified C template and tokenizer
# --------------------------------------------------------------------------
class ChatMsg(ctypes.Structure):
    _fields_ = [("role", ctypes.c_int),
                ("content", ctypes.c_char_p),
                ("content_len", ctypes.c_size_t),
                ("has_reasoning", ctypes.c_int),
                ("reasoning", ctypes.c_char_p),
                ("reasoning_len", ctypes.c_size_t)]


class Tok:
    def __init__(self, lib_path, qtk_path):
        L = ctypes.CDLL(lib_path)
        L.qwen35_tok_open.restype = ctypes.c_void_p
        L.qwen35_tok_open.argtypes = [ctypes.c_char_p]
        L.qwen35_tok_eos.argtypes = [ctypes.c_void_p]
        L.qwen35_tok_n_vocab.argtypes = [ctypes.c_void_p]
        L.qwen35_tok_chat_template.restype = ctypes.c_char_p
        L.qwen35_tok_chat_template.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
        L.qwen35_tok_piece.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p,
                                       ctypes.c_int, ctypes.c_int]
        L.qwen35_tok_attr.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.qwen35_chat_tokenize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ChatMsg), ctypes.c_int,
                                           ctypes.c_int, ctypes.c_int,
                                           ctypes.POINTER(ctypes.c_int), ctypes.c_int,
                                           ctypes.POINTER(ctypes.c_int)]
        L.qwen35_chat_strerror.restype = ctypes.c_char_p
        L.qwen35_chat_strerror.argtypes = [ctypes.c_int]
        self.L = L
        self.t = L.qwen35_tok_open(qtk_path.encode())
        if not self.t:
            raise SystemExit("llmvhdl_server: cannot open tokenizer %s" % qtk_path)
        self.eos = L.qwen35_tok_eos(self.t)
        self.n_vocab = L.qwen35_tok_n_vocab(self.t)
        n = ctypes.c_size_t(0)
        tpl = L.qwen35_tok_chat_template(self.t, ctypes.byref(n))
        self.template = tpl.decode("utf-8", "replace") if tpl else ""

    def chat_ids(self, msgs, enable_thinking):
        """msgs: [(role_int, content_str, reasoning_str_or_None)] -> list of ids."""
        keep = []
        arr = (ChatMsg * len(msgs))()
        for i, (role, content, reasoning) in enumerate(msgs):
            c = content.encode("utf-8")
            keep.append(c)
            arr[i].role = role
            arr[i].content = c
            arr[i].content_len = len(c)
            if reasoning is not None:
                r = reasoning.encode("utf-8")
                keep.append(r)
                arr[i].has_reasoning = 1
                arr[i].reasoning = r
                arr[i].reasoning_len = len(r)
        needed = ctypes.c_int(0)
        cap = 4096
        while True:
            ids = (ctypes.c_int * cap)()
            rc = self.L.qwen35_chat_tokenize(self.t, arr, len(msgs), 1, 1 if enable_thinking else 0,
                                             ids, cap, ctypes.byref(needed))
            if rc == -10:            # QWEN35_CHAT_E_SHORT: *needed holds the size
                cap = needed.value + 16
                continue
            if rc < 0:
                raise ValueError(self.L.qwen35_chat_strerror(rc).decode())
            return list(ids[:rc])

    def piece(self, tid):
        buf = ctypes.create_string_buffer(256)
        n = self.L.qwen35_tok_piece(self.t, tid, buf, 256, 0)
        if n < 0:
            buf = ctypes.create_string_buffer(-n)
            n = self.L.qwen35_tok_piece(self.t, tid, buf, -n, 0)
        return buf.raw[:max(n, 0)]


# --------------------------------------------------------------------------
# Output shaping: reasoning split and stop strings, applied to the TEXT
# --------------------------------------------------------------------------
class Shaper:
    """Turns the decoded text stream into (reasoning_delta, content_delta)
    pairs.  With thinking on, the prompt ends inside `<think>\\n`, so text is
    reasoning until `</think>`.  Stop strings apply to content only.  Holds
    back just enough text that a marker split across two tokens is still
    seen."""
    END = "</think>"

    def __init__(self, thinking, stops):
        self.in_think = thinking
        self.stops = [s for s in stops if s]
        self.pending = ""
        self.content_started = False
        self.stopped = False

    def _hold(self):
        cands = [self.END] if self.in_think else self.stops
        return max([len(c) - 1 for c in cands] + [0])

    def feed(self, text, final=False):
        out = []
        self.pending += text
        while not self.stopped:
            if self.in_think:
                k = self.pending.find(self.END)
                if k >= 0:
                    if k:
                        out.append(("r", self.pending[:k]))
                    self.pending = self.pending[k + len(self.END):]
                    self.in_think = False
                    continue
            else:
                if not self.content_started:
                    stripped = self.pending.lstrip("\n")
                    if not stripped and not final:
                        break
                    self.pending = stripped
                    self.content_started = bool(stripped) or self.content_started
                hit = [(self.pending.find(s), s) for s in self.stops if self.pending.find(s) >= 0]
                if hit:
                    k, s = min(hit)
                    if k:
                        out.append(("c", self.pending[:k]))
                    self.pending = ""
                    self.stopped = True
                    break
            hold = 0 if final else self._hold()
            emit = self.pending[:max(0, len(self.pending) - hold)]
            if emit:
                out.append(("r" if self.in_think else "c", emit))
                self.pending = self.pending[len(emit):]
            break
        return out


# --------------------------------------------------------------------------
# The card run
# --------------------------------------------------------------------------
class CardError(Exception):
    pass


def jc_base_cmd(a, pf, max_new):
    """The --jc* options shared by every run_prompt invocation against the Jungle Cat: the
    per-request host-driven run (Engine._run) and the loop-mode startup --open-only call.
    Callers add whatever else they need (--stream/--ids-stream, or --stop/--open-only)."""
    cmd = [RUN_PROMPT, "--jc", a.jc_sock, "--jc-die", a.jc_die0,
           "--jc-die2", a.jc_die1, "--seq-reset", "--v2",
           "--dtbl", os.path.join(a.jc_run0, "token.dtbl"),
           "--rel", os.path.join(a.jc_run0, "token.rel"),
           "--dtbl2", os.path.join(a.jc_run1, "token.dtbl"),
           "--rel2", os.path.join(a.jc_run1, "token.rel"),
           "--manifest", a.jc_man0, "--manifest2", a.jc_man1,
           "--prompt", pf, "--qtk", a.qtk, "--max-new", str(max_new)]
    if a.jc_emb:
        cmd += ["--mv4i", a.jc_emb]
    return cmd


def jc_loop_open_once(a):
    """Loop mode (--jc-loop-host): tools/jc/jc_loop.py only drives already-programmed dies
    and never touches the token programs itself, so stream them once at startup through the
    normal host path (--open-only), with the same --jc* options the non-loop per-request runs
    use. A failure here fails startup: there is no point serving requests jc_loop cannot run."""
    os.makedirs(a.run_dir, exist_ok=True)
    pf = os.path.join(a.run_dir, "startup_open_only.ids")
    with open(pf, "w") as f:
        f.write("0\n")
    cmd = jc_base_cmd(a, pf, 1) + ["--stop", "-1",
                                   "--ids-out", os.path.join(a.run_dir, "startup_open_only_out.txt"),
                                   "--open-only"]
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise SystemExit("llmvhdl_server: --jc-loop-host startup --open-only failed (rc %d):\n%s\n%s"
                         % (r.returncode, r.stdout[-2000:], r.stderr[-2000:]))


def jc_loop_script(a, ids, max_new, stop_id):
    """The bash script run over ssh on the BC-250: writes the prompt ids, records jc_loop's
    pid for Stop, then execs jc_loop.py with its own stdout/stderr redirected to a remote log
    (fd 3, saved before the redirect, carries the streamed ids back over the ssh channel)."""
    dirq = shlex.quote(a.jc_loop_dir)
    body = "".join("%d\n" % i for i in ids)
    lines = [
        "DIR=%s" % dirq,
        "cat > \"$DIR/ui_req.ids\" <<'EOF'",
        body + "EOF",
        "echo $$ > \"$DIR/ui_loop.pid\"",
        "exec 3>&1 >>\"$DIR/ui_loop.log\" 2>&1",
        "cd \"$DIR\"",
        "exec %s tools/jc/jc_loop.py --sock %s --die %s --die2 %s --prompt \"$DIR/ui_req.ids\" "
        "--max-new %d --stop %d --mv4i %s --ids-out \"$DIR/ui_last.ids\" --resend-max 1000 "
        "--ids-stream /dev/fd/3"
        % (shlex.quote(a.jc_loop_python), shlex.quote(a.jc_loop_sock), shlex.quote(a.jc_die0),
           shlex.quote(a.jc_die1), max_new, stop_id, shlex.quote(a.jc_loop_emb)),
    ]
    return "\n".join(lines) + "\n"


class Engine:
    def __init__(self, a, tok):
        self.a = a
        self.tok = tok
        self.lock = threading.Lock()
        self.n = 0
        self.busy_since = None
        os.makedirs(a.run_dir, exist_ok=True)

    def generate(self, ids, max_new, on_id, should_stop):
        """Run one sequence on the card(s).  on_id(tid) per generated id.
        should_stop() polled between ids; True sends SIGTERM (clean stop
        after the GO in flight).  Returns a dict of run facts."""
        with self.lock:
            self.busy_since = time.time()
            try:
                return self._run(ids, max_new, on_id, should_stop)
            finally:
                self.busy_since = None

    def _run(self, ids, max_new, on_id, should_stop):
        self.n += 1
        d = os.path.join(self.a.run_dir, "req_%s_%04d" % (time.strftime("%Y%m%d_%H%M%S"), self.n))
        os.makedirs(d)
        pf = os.path.join(d, "prompt.ids")
        with open(pf, "w") as f:
            f.write("".join("%d\n" % i for i in ids))
        if self.a.mode == "jc" and self.a.jc_loop_host:
            return self._run_jc_loop(d, ids, max_new, on_id, should_stop)
        r, w = os.pipe()
        if self.a.mode == "jc":
            env = dict(os.environ)
            cmd = jc_base_cmd(self.a, pf, max_new) + ["--stream", "--quiet",
                                                       "--ids-stream", "/dev/fd/%d" % w]
        else:
            env = dict(os.environ, FK33_PROMPT_IDS=pf)
            cmd = ["bash", CHAT[self.a.mode], "llm.vhdl web request", str(max_new),
                   "--ids-stream", "/dev/fd/%d" % w]
        t0 = time.time()
        with open(os.path.join(d, "stdout.txt"), "wb") as so, \
             open(os.path.join(d, "stderr.txt"), "wb") as se:
            p = subprocess.Popen(cmd, cwd=REPO, env=env, stdout=so, stderr=se,
                                 pass_fds=(w,), start_new_session=True)
            os.close(w)
            rf = os.fdopen(r, "rb", buffering=0)
            buf = b""
            got = []
            t_first = t_last = None
            termed = False
            while True:
                if not termed and should_stop():
                    try:
                        p.send_signal(signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    termed = True
                rl, _, _ = select.select([rf], [], [], 0.5)
                if not rl:
                    if p.poll() is not None:
                        # The writer is gone and nothing is readable: drain.
                        rest = rf.read()
                        if not rest:
                            break
                        buf += rest
                    else:
                        continue
                else:
                    chunk = rf.read(4096)
                    if not chunk:
                        break
                    buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    tid = int(line)
                    now = time.time()
                    if t_first is None:
                        t_first = now
                    t_last = now
                    got.append(tid)
                    on_id(tid)
            rf.close()
            rc = p.wait()
        err = open(os.path.join(d, "stderr.txt"), "rb").read().decode("utf-8", "replace")
        out = open(os.path.join(d, "stdout.txt"), "rb").read().decode("utf-8", "replace")
        facts = {"rc": rc, "dir": d, "ids": got, "t0": t0, "t_first": t_first,
                 "t_last": t_last, "t_end": time.time(), "termed": termed,
                 "stdout_tail": out[-2000:], "stderr_tail": err[-2000:]}
        with open(os.path.join(d, "facts.json"), "w") as f:
            json.dump({k: v for k, v in facts.items() if k != "ids"} | {"n_ids": len(got)}, f, indent=1)
        if rc != 0 and not termed:
            raise CardError(summarise_failure(err, out, rc, d, self.a.mode), facts)
        return facts

    # -- jc loop mode: jc_loop.py on the BC-250, driven over ssh ----------
    STOP_WAIT_S = 15.0

    def _run_jc_loop(self, d, ids, max_new, on_id, should_stop):
        """Launch `ssh HOST bash -s` running jc_loop_script()'s script; ids arrive on the
        ssh process's own stdout (fd 3 in the remote script), one per line, read the same
        way the non-loop path reads its pipe. Stop runs a second, short-lived ssh call that
        kills jc_loop's pid remotely, then waits for the main ssh to exit (falling back to a
        local terminate() after STOP_WAIT_S)."""
        t0 = time.time()
        script = jc_loop_script(self.a, ids, max_new, self.tok.eos)
        ssh_argv = shlex.split(self.a.jc_loop_ssh_cmd) + [self.a.jc_loop_host, "bash", "-s"]
        with open(os.path.join(d, "stdout.txt"), "wb") as so, \
             open(os.path.join(d, "stderr.txt"), "wb") as se:
            p = subprocess.Popen(ssh_argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=se, bufsize=0, start_new_session=True)
            p.stdin.write(script.encode())
            p.stdin.close()
            rf = p.stdout
            buf = b""
            got = []
            t_first = t_last = None
            termed = False
            term_sent_at = None
            local_killed = False
            while True:
                if not termed and should_stop():
                    self._stop_remote()
                    termed = True
                    term_sent_at = time.time()
                if (termed and not local_killed and p.poll() is None
                        and time.time() - term_sent_at > self.STOP_WAIT_S):
                    try:
                        p.terminate()
                    except ProcessLookupError:
                        pass
                    local_killed = True
                rl, _, _ = select.select([rf], [], [], 0.5)
                if not rl:
                    if p.poll() is not None:
                        rest = rf.read()
                        if not rest:
                            break
                        buf += rest
                        so.write(rest); so.flush()
                    else:
                        continue
                else:
                    chunk = rf.read(4096)
                    if not chunk:
                        break
                    buf += chunk
                    so.write(chunk); so.flush()
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    tid = int(line)
                    now = time.time()
                    if t_first is None:
                        t_first = now
                    t_last = now
                    got.append(tid)
                    on_id(tid)
            rf.close()
            rc = p.wait()
        log_tail = self._fetch_remote_log_tail(d)
        err = open(os.path.join(d, "stderr.txt"), "rb").read().decode("utf-8", "replace")
        out = open(os.path.join(d, "stdout.txt"), "rb").read().decode("utf-8", "replace")
        err_and_tail = (err + "\n" + log_tail) if log_tail else err
        facts = {"rc": rc, "dir": d, "ids": got, "t0": t0, "t_first": t_first,
                 "t_last": t_last, "t_end": time.time(), "termed": termed,
                 "stdout_tail": out[-2000:], "stderr_tail": err_and_tail[-2000:]}
        with open(os.path.join(d, "facts.json"), "w") as f:
            json.dump({k: v for k, v in facts.items() if k != "ids"} | {"n_ids": len(got)}, f, indent=1)
        if rc != 0 and not termed:
            raise CardError(summarise_failure(err_and_tail, out, rc, d, self.a.mode), facts)
        return facts

    def _stop_remote(self):
        """A second, short ssh call: kill -TERM the pid jc_loop_script() wrote, but only if
        the pid file exists and /proc/PID/exe is a python (never pkill/pgrep -- CLAUDE.md)."""
        dirq = shlex.quote(self.a.jc_loop_dir)
        script = (
            'PIDFILE=%s/ui_loop.pid\n'
            'if [ -f "$PIDFILE" ]; then\n'
            '  PID=$(cat "$PIDFILE" 2>/dev/null)\n'
            '  EXE=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)\n'
            '  case "$EXE" in\n'
            '    */python*) kill -TERM "$PID" ;;\n'
            '  esac\n'
            'fi\n'
        ) % dirq
        ssh_argv = shlex.split(self.a.jc_loop_ssh_cmd) + [self.a.jc_loop_host, "bash", "-s"]
        try:
            subprocess.run(ssh_argv, input=script.encode(), capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            pass   # best effort: the STOP_WAIT_S local terminate() still covers it

    def _fetch_remote_log_tail(self, d):
        """One more ssh call, after the run, so a failure is diagnosable even though the
        remote jc_loop.py's own stdout/stderr never crossed the ssh channel (fd 3 did)."""
        dirq = shlex.quote(self.a.jc_loop_dir)
        script = "tail -c 4000 %s/ui_loop.log 2>/dev/null || true\n" % dirq
        ssh_argv = shlex.split(self.a.jc_loop_ssh_cmd) + [self.a.jc_loop_host, "bash", "-s"]
        try:
            r = subprocess.run(ssh_argv, input=script.encode(), capture_output=True, timeout=15)
            tail = r.stdout.decode("utf-8", "replace")
        except (OSError, subprocess.TimeoutExpired) as e:
            tail = "(could not fetch ui_loop.log: %s)" % e
        with open(os.path.join(d, "ui_loop_log_tail.txt"), "w") as f:
            f.write(tail)
        return tail


def summarise_failure(err, out, rc, d, mode):
    lines = [l for l in (err + "\n" + out).splitlines() if l.strip()]
    key = [l for l in lines if re.search(r"returned -?\d|ERR_INFO|REFUS|FAIL|cannot|error", l, re.I)]
    msg = "; ".join((key or lines)[-3:])[:600]
    hint = ""
    if mode == "jc":
        if re.search(r"WindowUnknown|pl_open refused|broker", err + out, re.I):
            hint = " The broker or a die reported a fault; check it before the next request."
    elif re.search(r"WDOG|seq-reset FAILED|D code 4", err + out):
        hint = " The card reported a unit timeout; it needs a JTAG reload before the next request."
    what = "the Jungle Cat run" if mode == "jc" else "the FK33 run"
    return "%s failed (rc %d): %s.%s Logs: %s" % (what, rc, msg, hint, d)


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
def model_id(a):
    if a.mode == "jc":
        return "qwen3.8-27b-jc"
    return "qwen3.5-9b-fk33-%s" % a.mode


def props(a, tok):
    params = {
        "n_predict": -1, "seed": -1, "temperature": 0.0, "dynatemp_range": 0.0,
        "dynatemp_exponent": 1.0, "top_k": 1, "top_p": 1.0, "min_p": 0.0,
        "top_n_sigma": -1.0, "xtc_probability": 0.0, "xtc_threshold": 0.1,
        "typ_p": 1.0, "repeat_last_n": 0, "repeat_penalty": 1.0,
        "presence_penalty": 0.0, "frequency_penalty": 0.0, "dry_multiplier": 0.0,
        "dry_base": 1.75, "dry_allowed_length": 2, "dry_penalty_last_n": -1,
        "dry_sequence_breakers": [], "mirostat": 0, "mirostat_tau": 5.0,
        "mirostat_eta": 0.1, "stop": [], "max_tokens": -1, "n_keep": 0,
        "n_discard": 0, "ignore_eos": False, "stream": True, "logit_bias": [],
        "n_probs": 0, "min_keep": 0, "grammar": "", "samplers": ["greedy"],
        "speculative.n_max": 0, "speculative.n_min": 0, "speculative.p_min": 0.0,
        "timings_per_token": False, "post_sampling_probs": False, "lora": [],
    }
    return {
        "default_generation_settings": {"id": 0, "id_task": -1, "n_ctx": a.n_ctx,
                                        "speculative": False, "is_processing": False,
                                        "params": params},
        "total_slots": 1,
        "model_alias": model_id(a),
        "model_path": ("Qwen3.8-27B on the Jungle Cat (2 dies, VHDL). Greedy only; every turn"
                       " re-prefills." if a.mode == "jc" else
                       "Qwen3.5-9B on %s (FK33, VHDL). Greedy only; every turn re-prefills."
                       % ("two cards" if a.mode == "pair" else "one card")),
        "modalities": {"vision": False, "video": False, "audio": False},
        "media_marker": "",
        "endpoint_slots": False, "endpoint_props": False, "endpoint_metrics": False,
        "ui": True, "ui_settings": {}, "chat_template": tok.template,
        "chat_template_caps": {}, "bos_token": "", "eos_token": "<|im_end|>",
        "build_info": "llm.vhdl (Jungle Cat)" if a.mode == "jc" else "llm.vhdl (FK33 %s)" % a.mode,
        "is_sleeping": False,
        "cors_proxy_enabled": False,
    }


def flatten_content(c):
    if c is None:
        return ""
    if isinstance(c, str):
        return c
    parts = []
    for p in c:
        if isinstance(p, dict) and p.get("type") == "text":
            parts.append(p.get("text", ""))
        elif isinstance(p, dict):
            raise ValueError("content part '%s' is not supported: this model is text only"
                             % p.get("type"))
    return "".join(parts)


class Handler(BaseHTTPRequestHandler):
    server_version = "llm.vhdl"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # -- plumbing ---------------------------------------------------------
    def _send(self, code, body, ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _err(self, code, msg, typ="invalid_request_error", **more):
        e = {"code": code, "message": msg, "type": typ}
        e.update(more)
        self._send(code, {"error": e})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        a, tok = self.server.a, self.server.tok
        path = urlparse(self.path).path
        if path in ("/health", "/v1/health"):
            return self._send(200, {"status": "ok"})
        if path == "/props":
            return self._send(200, props(a, tok))
        if path in ("/v1/models", "/models"):
            m = {"id": model_id(a), "object": "model", "created": int(self.server.t_start),
                 "owned_by": "llm.vhdl",
                 "meta": {"n_ctx_train": a.n_ctx, "n_vocab": tok.n_vocab}}
            return self._send(200, {"object": "list", "data": [m],
                                    "models": [{"name": model_id(a), "model": model_id(a)}]})
        if path == "/slots":
            return self._err(501, "slots are not exposed by llm.vhdl", "not_supported_error")
        # API-shaped paths never fall back to index.html: the UI parses them as
        # JSON (MEASURED 2026-09-24: GET /tools answered 200 text/html).
        if path.startswith(("/tools", "/models/", "/v1/", "/cors-proxy", "/metrics")):
            return self._err(404, "not supported by llm.vhdl: %s" % path, "not_supported_error")
        return self._static(path)

    def _static(self, path):
        root = self.server.a.ui_dir
        rel = path.lstrip("/") or "index.html"
        full = os.path.realpath(os.path.join(root, rel))
        if not full.startswith(os.path.realpath(root) + os.sep) or not os.path.isfile(full):
            if "." in os.path.basename(rel):
                return self._send(404, "not found", "text/plain")
            full = os.path.join(root, "index.html")      # SPA fallback
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        with open(full, "rb") as f:
            body = f.read()
        cache = {"Cache-Control": "no-cache"} if full.endswith((".html", "sw.js", ".json")) \
            else {"Cache-Control": "public, max-age=3600"}
        self._send(200, body, ctype, cache)

    def do_POST(self):
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if path in ("/v1/chat/completions", "/chat/completions"):
            try:
                req = json.loads(raw or b"{}")
            except ValueError:
                return self._err(400, "request body is not JSON")
            try:
                return self._chat(req)
            except (BrokenPipeError, ConnectionResetError):
                return
            except Exception as e:  # noqa: BLE001 -- surface, never hang the UI
                traceback.print_exc()
                try:
                    return self._err(500, "llm.vhdl server error: %s" % e, "server_error")
                except OSError:
                    return
        if path == "/v1/streams/lookup":
            return self._err(404, "resumable streams are not supported", "not_supported_error")
        if path == "/v1/chat/completions/control":
            return self._err(501, "not supported", "not_supported_error")
        return self._err(404, "no such endpoint: %s" % path)

    # -- the chat request -------------------------------------------------
    def _chat(self, req):
        a, tok, eng = self.server.a, self.server.tok, self.server.eng
        if req.get("tools"):
            return self._err(400, "tools are not supported by llm.vhdl")
        msgs = []
        for m in req.get("messages") or []:
            role = m.get("role")
            if role not in ROLE or role == "tool":
                return self._err(400, "message role '%s' is not supported" % role)
            try:
                content = flatten_content(m.get("content"))
            except ValueError as e:
                return self._err(400, str(e))
            rc = m.get("reasoning_content")
            msgs.append((ROLE[role], content, rc if isinstance(rc, str) and rc else None))
        kw = req.get("chat_template_kwargs") or {}
        thinking = bool(kw.get("enable_thinking", a.thinking))
        try:
            ids = tok.chat_ids(msgs, thinking)
        except ValueError as e:
            return self._err(400, "chat template refused the conversation: %s" % e)
        n_prompt = len(ids)
        room = a.n_ctx - n_prompt
        if room < 1:
            return self._err(400, "the prompt is %d tokens and the context is %d" % (n_prompt, a.n_ctx),
                             "exceed_context_size_error", n_prompt_tokens=n_prompt, n_ctx=a.n_ctx)
        want = req.get("max_tokens") or req.get("max_completion_tokens") or req.get("n_predict")
        if not isinstance(want, int) or want <= 0:
            want = a.max_new
        max_new = max(1, min(want, room))
        stops = req.get("stop") or []
        if isinstance(stops, str):
            stops = [stops]
        stream = bool(req.get("stream"))
        cid = "chatcmpl-llmvhdl-%d-%d" % (int(time.time()), threading.get_ident() % 100000)
        created = int(time.time())
        mid = model_id(a)
        shaper = Shaper(thinking, stops)
        dec = codecs.getincrementaldecoder("utf-8")("replace")
        st = {"headers": False, "gone": False, "reasoning": [], "content": [],
              "n_gen": 0, "eos": False}

        def chunk(delta, finish=None, extra=None):
            d = {"id": cid, "object": "chat.completion.chunk", "created": created, "model": mid,
                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if extra:
                d.update(extra)
            return ("data: %s\n\n" % json.dumps(d)).encode()

        def write(b):
            if st["gone"]:
                return
            try:
                if not st["headers"]:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    st["headers"] = True
                    self.wfile.write(chunk({"role": "assistant", "content": None}))
                self.wfile.write(b)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                st["gone"] = True

        def emit(parts):
            for kind, text in parts:
                (st["reasoning"] if kind == "r" else st["content"]).append(text)
                if stream:
                    write(chunk({"reasoning_content": text} if kind == "r" else {"content": text}))

        def on_id(tid):
            if tid == tok.eos:
                st["eos"] = True
                return
            st["n_gen"] += 1
            if shaper.stopped:
                return
            emit(shaper.feed(dec.decode(tok.piece(tid))))

        def should_stop():
            return st["gone"] or shaper.stopped

        try:
            facts = eng.generate(ids, max_new, on_id, should_stop)
            fail = None
        except CardError as e:
            facts = e.args[1]
            fail = e.args[0]
            if not st["headers"] and not st["n_gen"]:
                self.close_connection = True
                return self._err(503, fail, "server_error")
        emit(shaper.feed(dec.decode(b"", final=True), final=True))
        if fail:
            emit([("c", "\n\n[llm.vhdl: generation stopped by a card fault. %s]" % fail)])
        finish = "stop" if (st["eos"] or shaper.stopped or fail) else "length"
        tf, tl = facts.get("t_first"), facts.get("t_last")
        timings = {"prompt_n": n_prompt, "cache_n": 0,
                   "prompt_ms": ((tf or facts["t_end"]) - facts["t0"]) * 1000.0,
                   "predicted_n": st["n_gen"] + (1 if st["eos"] else 0),
                   "predicted_ms": ((tl - tf) * 1000.0) if tf and tl else 0.0}
        if timings["predicted_n"] > 1 and timings["predicted_ms"] > 0:
            timings["predicted_per_second"] = (timings["predicted_n"] - 1) * 1000.0 / timings["predicted_ms"]
        usage = {"prompt_tokens": n_prompt, "completion_tokens": timings["predicted_n"],
                 "total_tokens": n_prompt + timings["predicted_n"]}
        self.log_message("chat: prompt %d ids, %d generated, finish %s%s, prefill+setup %.1f s, "
                         "%.2f tok/s, run %s", n_prompt, timings["predicted_n"], finish,
                         " (client went away, stopped by SIGTERM)" if st["gone"] else "",
                         timings["prompt_ms"] / 1000.0, timings.get("predicted_per_second", 0.0),
                         facts["dir"])
        if stream:
            write(chunk({}, finish, {"timings": timings, "usage": usage}))
            write(b"data: [DONE]\n\n")
            self.close_connection = True
            return
        msg = {"role": "assistant", "content": "".join(st["content"])}
        if st["reasoning"]:
            msg["reasoning_content"] = "".join(st["reasoning"])
        self._send(200, {"id": cid, "object": "chat.completion", "created": created, "model": mid,
                         "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                         "usage": usage, "timings": timings})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1",
                    help="127.0.0.1 behind Caddy (https://llmvhdl.example.com, LAN only); "
                         "0.0.0.0 exposes the cards to the whole network with no auth")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--mode", choices=("pair", "single", "jc"), default="pair")
    ap.add_argument("--n-ctx", type=int, default=None,
                    help="context the UI is told; default 65536 on the FK33 (pair/single), "
                         "16384 on the Jungle Cat (jc: its C_MAXPOS)")
    ap.add_argument("--max-new", type=int, default=1024,
                    help="generated tokens when the request names none")
    ap.add_argument("--thinking", action="store_true",
                    help="enable the reasoning block by default (a request's "
                         "chat_template_kwargs.enable_thinking overrides)")
    ap.add_argument("--qtk", default=QTK_DEFAULT)
    ap.add_argument("--lib", default=LIB_DEFAULT)
    ap.add_argument("--ui-dir", default=UI_DEFAULT)
    ap.add_argument("--run-dir", default=RUN_DEFAULT,
                    help="per-request logs (prompt ids, run_prompt stdout/stderr)")
    ap.add_argument("--jc-sock", help="jc mode: the broker's Unix socket (required)")
    ap.add_argument("--jc-run0", help="jc mode: card 0's token program dir (token.dtbl, token.rel)")
    ap.add_argument("--jc-run1", help="jc mode: card 1's token program dir")
    ap.add_argument("--jc-man0", help="jc mode: card 0's manifest.json")
    ap.add_argument("--jc-man1", help="jc mode: card 1's manifest.json")
    ap.add_argument("--jc-emb", help="jc mode: the token embedding .mv4i")
    ap.add_argument("--jc-die0", default="A", help="jc mode: card 0's die on the broker (default A)")
    ap.add_argument("--jc-die1", default="B", help="jc mode: card 1's die on the broker (default B)")
    ap.add_argument("--jc-loop-host",
                    help="jc mode: USER@HOST of the BC-250; turns on loop mode, where a chat "
                         "request runs tools/jc/jc_loop.py there instead of run_prompt here")
    ap.add_argument("--jc-loop-dir",
                    help="loop mode: the remote directory holding tools/jc/jc_loop.py and its "
                         "siblings, the embedding file, and the broker socket")
    ap.add_argument("--jc-loop-sock", help="loop mode: the broker socket's path on the remote host")
    ap.add_argument("--jc-loop-emb", help="loop mode: the token embedding .mv4i's path on the remote host")
    ap.add_argument("--jc-loop-python", default="python3", help="loop mode: the remote python3 (default python3)")
    ap.add_argument("--jc-loop-ssh-cmd", default="ssh -o BatchMode=yes",
                    help=argparse.SUPPRESS)  # tests point this at a local fake ssh
    a = ap.parse_args()
    if a.n_ctx is None:
        a.n_ctx = JC_N_CTX_DEFAULT if a.mode == "jc" else 65536
    if not os.path.isfile(a.lib):
        raise SystemExit("llmvhdl_server: %s is missing; run `make -C server libqwen35chat.so`" % a.lib)
    if not os.path.isfile(os.path.join(a.ui_dir, "index.html")):
        raise SystemExit("llmvhdl_server: no UI at %s; see ui/README.md" % a.ui_dir)
    rp_bytes = open(RUN_PROMPT, "rb").read()
    if b"--ids-stream" not in rp_bytes:
        raise SystemExit("llmvhdl_server: server/run_prompt predates --ids-stream; run `make -C server run_prompt`")
    if a.mode == "jc":
        missing = [name for name, val in (
            ("--jc-sock", a.jc_sock), ("--jc-run0", a.jc_run0), ("--jc-run1", a.jc_run1),
            ("--jc-man0", a.jc_man0), ("--jc-man1", a.jc_man1),
        ) if not val]
        if missing:
            raise SystemExit("llmvhdl_server: --mode jc needs %s" % ", ".join(missing))
        if not a.jc_emb:
            print("llmvhdl_server: WARNING --jc-emb is not set; run_prompt falls back to the"
                  " synthetic embedding provider, which is not a model of anything", file=sys.stderr)
        if b"--jc " not in rp_bytes:
            raise SystemExit("llmvhdl_server: server/run_prompt predates --jc; run `make -C server run_prompt`")
        if a.jc_loop_host:
            missing = [name for name, val in (
                ("--jc-loop-dir", a.jc_loop_dir), ("--jc-loop-sock", a.jc_loop_sock),
                ("--jc-loop-emb", a.jc_loop_emb),
            ) if not val]
            if missing:
                raise SystemExit("llmvhdl_server: --jc-loop-host needs %s" % ", ".join(missing))
    elif a.jc_loop_host:
        raise SystemExit("llmvhdl_server: --jc-loop-host needs --mode jc")
    mimetypes.add_type("application/javascript", ".js")
    mimetypes.add_type("application/manifest+json", ".webmanifest")
    tok = Tok(a.lib, a.qtk)
    if a.mode == "jc" and a.jc_loop_host:
        jc_loop_open_once(a)
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    srv.daemon_threads = True
    srv.a, srv.tok, srv.eng, srv.t_start = a, tok, Engine(a, tok), time.time()
    print("llm.vhdl server: http://%s:%d/  mode %s, model %s, n_ctx %d, greedy only, "
          "one request at a time, logs %s%s" % (a.host, a.port, a.mode, model_id(a), a.n_ctx, a.run_dir,
                                                 " (loop mode on %s)" % a.jc_loop_host if a.jc_loop_host else ""),
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
