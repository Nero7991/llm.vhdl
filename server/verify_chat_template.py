#!/usr/bin/env python3
"""Check server/qwen35_chat.c against the model's OWN Jinja template, and the
ids it produces against llama.cpp.

THE ORACLE IS NOT THIS SCRIPT'S AUTHOR'S READING OF THE TEMPLATE.  It is
Jinja2 evaluating `tokenizer.chat_template` out of the GGUF, which is the same
artefact `transformers.apply_chat_template` and llama.cpp's `--jinja` both
evaluate.  The C never sees it; the Python never sees the C.

Three legs, in increasing strength:

  1. BYTES.  For every case, C-rendered bytes == Jinja2-rendered bytes.  This
     is the real check.  Everything the C could get wrong -- the trim rule, the
     </think> split, the last-user-query scan, the two thinking preambles, a
     missing newline -- shows up here as a byte difference, and a byte
     difference is not arguable.

  2. IDS.  The C's own ids (qwen35_tok_encode with parse_special = 1) ==
     llama.cpp's ids for the ORACLE's text.  Leg 1 already forces the texts
     equal, so this leg is specifically about parse_special: without it
     "<|im_start|>" tokenizes as ordinary text and every turn boundary is
     wrong, and leg 1 cannot see that at all.

  3. REFUSALS.  Every case the C refuses must be one Jinja2 also raises on,
     OR one of the four codes qwen35_chat.h documents as deliberately out of
     scope (TOOLROLE, TOOLS, TOOLCALLS, VISION).  A refusal outside that set is
     a coverage REGRESSION and fails the run; a deliberate one is counted and
     printed, so the scope cannot shrink quietly.

--mutate NAME breaks the C on purpose (see MUTATIONS) and expects the
comparison to FAIL.  A checker never shown to fail has not been shown to work,
and mutations that do NOT bite are reported under their own names because they
measure the resolution floor.

    server/verify_chat_template.py --build
    server/verify_chat_template.py --build --ids \\
        --qtk build_artifacts_tok/qwen35_9b.qtk \\
        --oracle build_artifacts_tok/tok_oracle_batch \\
        --gguf /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
"""

import argparse
import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ROLE = {"system": 0, "user": 1, "assistant": 2, "tool": 3}

# Refusals qwen35_chat.h documents as deliberate: the template renders these
# and this renderer will not.  They are counted, not tolerated silently -- if
# this set ever grows, the growth is visible in the run output.
DELIBERATE = {-4, -5, -6, -7}

# QWEN35_CHAT_E_* from server/qwen35_chat.h.
E = {
    -1: "NOMSGS", -2: "SYSPOS", -3: "ROLE", -4: "TOOLROLE", -5: "TOOLS",
    -6: "TOOLCALLS", -7: "VISION", -8: "NOQUERY", -9: "OOM", -10: "SHORT",
}

# Each mutation is (name, sed-style (old, new)) applied to a COPY of
# server/qwen35_chat.c.  They are chosen to be the mistakes a transcription of
# this particular template actually makes.
MUTATIONS = {
    # the header comment says the default branch is the CLOSED block; getting
    # it backwards is the single most likely error and is invisible to any
    # self-consistency check.
    "think-default": ('enable_thinking ? "<think>\\n" : "<think>\\n\\n</think>\\n\\n"',
                      'enable_thinking ? "<think>\\n\\n</think>\\n\\n" : "<think>\\n"'),
    # ASCII-only trim.  Bites only on a case with unicode whitespace at an edge.
    "ascii-trim":    ('    if (cp >= 0x1Cu && cp <= 0x1Fu)\n        return 1;',
                      '    if (cp >= 0x1Cu && cp <= 0x1Fu)\n        return 1;\n    if (cp > 0x7Fu) return 0;'),
    # drop the trailing newline after <|im_end|> on a user turn
    "user-newline":  ('            ob_lit(&o, "<|im_start|>user\\n");\n'
                      '            ob_put(&o, c, cl);\n'
                      '            ob_lit(&o, "<|im_end|>\\n");',
                      '            ob_lit(&o, "<|im_start|>user\\n");\n'
                      '            ob_put(&o, c, cl);\n'
                      '            ob_lit(&o, "<|im_end|>");'),
    # the reasoning block is emitted for turns AFTER the last user query; use
    # >= instead of >.  MEASURED: this DOES NOT BITE, and the reason is a
    # proof rather than a coverage gap -- last_query_index is by construction
    # the index of a USER message, a user message never reaches the assistant
    # branch, and the one list where no user index exists raises NOQUERY
    # instead.  So the two spellings are equal on every reachable input.
    # Retained under its own name because a mutation that cannot bite is worth
    # more written down than deleted.
    "last-query":    ('if (i > last_query_index) {', 'if (i >= last_query_index) {'),
    # skip the reverse scan entirely and take the template's DEFAULT
    # last_query_index of len-1.  This is the mutation that actually probes the
    # multi_step_tool logic, and it needs a case with a bare <tool_response>
    # user turn after a real query to be observable at all.
    "last-query-default": ('    if (multi_step_tool) return QWEN35_CHAT_E_NOQUERY;',
                           '    if (multi_step_tool) return QWEN35_CHAT_E_NOQUERY;\n'
                           '    last_query_index = n - 1;'),
    # split on the FIRST </think> for the body instead of the last
    "think-split":   ('body     = c + (size_t)lastclose + strlen("</think>");',
                      'body     = c + (size_t)close + strlen("</think>");'),
    # forget to trim the reasoning
    "reason-trim":   ('    qwen35_chat_trim(reason, reason_len, &reason, &reason_len);',
                      '    /* no trim */;'),
    # the system message emitted inside the body loop as well as before it
    "system-twice":  ('        if (msgs[i].role == QWEN35_ROLE_SYSTEM) {\n'
                      '            /* Already emitted above; the template\'s body loop only checks the\n'
                      '             * position, which we validated. */\n'
                      '            continue;',
                      '        if (msgs[i].role == QWEN35_ROLE_SYSTEM) {\n'
                      '            ob_lit(&o, "<|im_start|>system\\n");\n'
                      '            ob_put(&o, c, cl);\n'
                      '            ob_lit(&o, "<|im_end|>\\n");\n'
                      '            continue;'),
    # tokenize without parse_special.  Leg 1 cannot see this; leg 2 must.
    "no-special":    ('rc = qwen35_tok_encode(tk, txt, (size_t)got, ids, max, 1);',
                      'rc = qwen35_tok_encode(tk, txt, (size_t)got, ids, max, 0);'),
}


# ------------------------------------------------------------------ the cases

def build_cases(seed, n_random):
    """(messages, add_generation_prompt, enable_thinking) triples.

    Hand-written cases first, because the interesting ones are structural and
    random text will never produce them; random cases after, because the trim
    rule and the </think> split are byte-level and want volume.
    """
    cases = []

    def c(msgs, agp=1, think=0):
        cases.append((msgs, agp, think))

    U = lambda t: {"role": "user", "content": t}
    A = lambda t, **kw: dict({"role": "assistant", "content": t}, **kw)
    S = lambda t: {"role": "system", "content": t}

    # --- the shapes a server actually sees
    c([U("hello")])
    c([U("hello")], agp=0)
    c([U("hello")], think=1)
    c([S("You are terse."), U("hi")])
    c([S("You are terse."), U("hi"), A("Hi."), U("again")])
    c([U("a"), A("b"), U("c"), A("d"), U("e")])
    c([U("only user, no generation prompt")], agp=0)

    # --- the </think> split, in every arrangement that changes the answer
    c([U("q"), A("<think>\nreasoning here\n</think>\n\nthe answer"), U("q2")])
    c([U("q"), A("<think>\nreasoning here\n</think>\n\nthe answer")])
    c([U("q"), A("no think block at all")])
    c([U("q"), A("</think>\nbody only, no opening tag")])
    c([U("q"), A("<think>one</think>mid<think>two</think>tail")])
    c([U("q"), A("<think>\n\n</think>\n\n")])
    c([U("q"), A("body", reasoning_content="explicit reasoning")])
    c([U("q"), A("<think>\nignored\n</think>\nbody", reasoning_content="wins")])
    c([U("q"), A("  \n\n  spaced  \n\n  ")])

    # --- a trailing assistant turn, which the template re-emits with a
    #     reasoning block because its index is past the last user query
    c([U("q"), A("first"), A("second")])
    c([U("q"), A("first"), A("<think>\nr\n</think>\n\nsecond")])

    # --- trim, at the edges the ASCII rule gets wrong
    for w in (" ", " ", "　", "", " ", "﻿"):
        c([U(w + "padded" + w)])
        c([S(w + "sys" + w), U("q")])
    c([U("\t\n\r\v\f mixed \t\n\r\v\f")])
    c([U("​zero width space is NOT whitespace​")])

    # --- empty and near-empty content
    c([U("")])
    c([U(" ")])
    c([S(""), U("q")])
    c([U("q"), A("")])

    # --- multi-byte and emoji, because the trim walks UTF-8 backwards
    c([U("日本語のテキスト")])
    c([U("  \U0001F600 emoji  ")])
    c([U("Ĝis ġi tie")])

    # --- a user turn that LOOKS like a tool response.  This is the one that
    #     drives ns.multi_step_tool, and getting it wrong changes which
    #     assistant turns get a reasoning block.
    c([U("real query"), A("a"), U("<tool_response>x</tool_response>")])
    c([U("real query"), A("a"), U("<tool_response>x</tool_response>"), A("b")])
    c([U("  <tool_response>trimmed</tool_response>  ")])   # -> NOQUERY

    # --- refusals
    c([])                                                   # NOMSGS
    c([U("a"), S("late system")])                           # SYSPOS
    c([{"role": "tool", "content": "x"}, U("q")])           # TOOLROLE
    c([{"role": "banana", "content": "x"}, U("q")])         # ROLE
    c([A("assistant only")])                                # NOQUERY

    rng = random.Random(seed)
    alphabet = ("abc XYZ \n\t <think> </think> <|im_start|> <|im_end|> "
                "  　 \U0001F600 ​ <tool_response> </tool_response> ")
    pieces = alphabet.split(" ")
    for _ in range(n_random):
        n = rng.randint(1, 5)
        msgs = []
        if rng.random() < 0.3:
            msgs.append(S("".join(rng.choice(pieces) for _ in range(rng.randint(0, 6)))))
        for k in range(n):
            role = "user" if k % 2 == 0 else "assistant"
            txt = "".join(rng.choice(pieces) for _ in range(rng.randint(0, 12)))
            msgs.append({"role": role, "content": txt})
        cases.append((msgs, rng.randint(0, 1), rng.randint(0, 1)))

    return cases


# ---------------------------------------------------------------- the oracle

def load_template(qtk_path, jinja_path):
    if jinja_path and os.path.exists(jinja_path):
        with open(jinja_path, "rb") as f:
            return f.read().decode("utf-8")
    # read section 5 of the .qtk directly, so the oracle's template comes from
    # the same artefact the C loads and cannot drift from it
    with open(qtk_path, "rb") as f:
        head = f.read(168 + 8 * 8)
    if head[:4] != b"QTK1":
        raise SystemExit(f"{qtk_path}: not a QTK1 artefact")
    off, ln = struct.unpack_from("<II", head, 168 + 8 * 5)
    with open(qtk_path, "rb") as f:
        f.seek(off)
        return f.read(ln).decode("utf-8")


def make_env(template_src):
    import jinja2

    def raise_exception(msg):
        raise ValueError(msg)

    # These four settings are transformers' own, from
    # PreTrainedTokenizerBase._compile_jinja_template: an ImmutableSandboxed
    # environment with trim_blocks and lstrip_blocks on, the loopcontrols
    # extension, and a raise_exception global.  They are NOT arbitrary:
    #
    #   * the DEFAULT Undefined, not StrictUndefined.  The template reads
    #     `message.tool_calls` and `message.reasoning_content` on every
    #     assistant turn, and a message dict without those keys is the normal
    #     case.  Under StrictUndefined the oracle raises on ordinary chats --
    #     MEASURED, it raised on 167 of 247 cases in the first run of this
    #     script, which read as "the C accepted something the template
    #     refuses" and was entirely the harness.
    #   * loopcontrols, for the {%- break %} the template does not actually
    #     use but transformers enables anyway; kept so the environment matches.
    env = jinja2.Environment(
        trim_blocks=True, lstrip_blocks=True,
        extensions=["jinja2.ext.loopcontrols"],
    )
    env.policies["json.dumps_kwargs"] = {"ensure_ascii": False}
    env.globals["raise_exception"] = raise_exception
    return env.from_string(template_src)


def render_oracle(tmpl, msgs, agp, think):
    """Returns (text, None) or (None, 'reason')."""
    try:
        out = tmpl.render(messages=msgs, add_generation_prompt=bool(agp),
                          enable_thinking=bool(think), tools=None,
                          add_vision_id=False)
    except Exception as exc:                       # noqa: BLE001
        return None, f"{type(exc).__name__}: {exc}"
    return out, None


# ------------------------------------------------------------- the C process

def pack_cases(cases):
    p = bytearray(struct.pack("<I", len(cases)))
    for msgs, agp, think in cases:
        p += struct.pack("<III", len(msgs), agp, think)
        for m in msgs:
            role = ROLE.get(m["role"], 4)
            content = (m.get("content") or "").encode("utf-8")
            reason = (m.get("reasoning_content") or "").encode("utf-8")
            has_r = 1 if "reasoning_content" in m else 0
            p += struct.pack("<I", role)
            p += struct.pack("<I", len(content)) + content
            p += struct.pack("<I", has_r)
            p += struct.pack("<I", len(reason)) + reason
    return bytes(p)


def run_c(binary, cases, qtk=None):
    args = [binary]
    if qtk:
        args += ["--tokenize", qtk]
    p = subprocess.run(args, input=pack_cases(cases), stdout=subprocess.PIPE)
    if p.returncode != 0:
        raise SystemExit(f"{binary} exited {p.returncode}")
    buf, pos = p.stdout, 0
    n = struct.unpack_from("<I", buf, pos)[0]; pos += 4
    if n != len(cases):
        raise SystemExit(f"{binary} returned {n} cases, expected {len(cases)}")
    out = []
    for _ in range(n):
        rc = struct.unpack_from("<i", buf, pos)[0]; pos += 4
        ln = struct.unpack_from("<I", buf, pos)[0]; pos += 4
        txt = bytes(buf[pos:pos + ln]); pos += ln
        ids = None
        if qtk:
            k = struct.unpack_from("<I", buf, pos)[0]; pos += 4
            ids = list(struct.unpack_from(f"<{k}i", buf, pos)) if k else []
            pos += 4 * k
        out.append((rc, txt, ids))
    return out


def run_llamacpp(oracle, gguf, texts):
    """tools/tok_oracle_batch's protocol: u32 count, then length-prefixed."""
    p = bytearray(struct.pack("<I", len(texts)))
    for t in texts:
        p += struct.pack("<I", len(t)) + t
    r = subprocess.run([oracle, gguf], input=bytes(p), stdout=subprocess.PIPE)
    if r.returncode != 0:
        raise SystemExit(f"{oracle} exited {r.returncode}")
    buf, pos, out = r.stdout, 0, []
    for _ in range(len(texts)):
        k = struct.unpack_from("<I", buf, pos)[0]; pos += 4
        out.append(list(struct.unpack_from(f"<{k}i", buf, pos)) if k else [])
        pos += 4 * k
    return out


# -------------------------------------------------------------------- build

def build(dst, mutate=None):
    src = os.path.join(HERE, "qwen35_chat.c")
    work = src
    tmp = None
    if mutate:
        if mutate not in MUTATIONS:
            raise SystemExit(f"unknown mutation {mutate}; have {sorted(MUTATIONS)}")
        old, new = MUTATIONS[mutate]
        text = open(src, encoding="utf-8").read()
        if mutate == "no-special":
            pass
        if old not in text:
            raise SystemExit(f"mutation {mutate!r}: anchor not found in {src}.\n"
                             f"  The file moved under the mutation table; fix the table.\n"
                             f"  anchor: {old[:80]!r}")
        tmp = os.path.join(os.path.dirname(dst), f"qwen35_chat_{mutate}.c")
        open(tmp, "w", encoding="utf-8").write(text.replace(old, new, 1))
        work = tmp
    cmd = ["cc", "-O2", "-std=c99", "-Wall", "-Wextra",
           os.path.join(HERE, "tests", "chat_batch.c"), work,
           os.path.join(HERE, "qwen35_tok.c"),
           os.path.join(HERE, "qwen35_unicode_data.c"),
           "-I" + HERE, "-o", dst]
    subprocess.run(cmd, check=True)
    return tmp


def show(b, n=110):
    r = repr(b)
    return r if len(r) <= n else r[:n - 3] + "..."


# --------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qtk", default=os.path.join(ROOT, "build_artifacts_tok",
                                                  "qwen35_9b.qtk"))
    ap.add_argument("--jinja", default=os.path.join(ROOT, "build_artifacts_tok",
                                                    "qwen35_chat_template.jinja"))
    ap.add_argument("--cbin", default=os.path.join(ROOT, "build_artifacts_tok",
                                                   "chat_batch"))
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--mutate", default=None)
    ap.add_argument("--ids", action="store_true",
                    help="also run leg 2, the llama.cpp id comparison")
    ap.add_argument("--oracle", default=os.path.join(ROOT, "build_artifacts_tok",
                                                     "tok_oracle_batch"))
    ap.add_argument("--gguf", default="/mnt/storage/llama-models/qwen35-9b/"
                                      "Qwen3.5-9B-BF16.gguf")
    ap.add_argument("--seed", type=int, default=20260829)
    ap.add_argument("--n-random", type=int, default=2000)
    ap.add_argument("--show", type=int, default=6, help="max mismatches to print")
    a = ap.parse_args()

    # A MUTANT NEVER GETS THE DEFAULT BINARY PATH.  MEASURED 2026-09-02: a
    # `--build --mutate think-default` run compiled the mutant to `--cbin`
    # and LEFT IT THERE, so the next plain run -- which does not rebuild --
    # silently tested the mutant and reported
    # `leg 1 bytes: 992 identical, 1045 DIFFER ... CHAT_TEMPLATE FAIL`.
    # That reads exactly like a regression in qwen35_chat.c, and it cost half
    # an hour of hunting one: the C was correct, the harness was running last
    # week's mutant.  Suffixing the path means a mutation run can never poison
    # the clean binary, and the two can coexist.
    cbin = a.cbin + ("." + a.mutate if a.mutate else "")

    if a.build:
        build(cbin, a.mutate)
    elif a.mutate:
        raise SystemExit("--mutate needs --build")

    # A BINARY THIS RUN DID NOT BUILD IS NOT EVIDENCE ABOUT THIS TREE.  Without
    # --build the comparison is against whatever was compiled last, which may
    # predate every source change since.  Refuse rather than report on it.
    if not a.build:
        if not os.path.exists(cbin):
            raise SystemExit(f"{cbin} does not exist; run with --build")
        newer = [f for f in (os.path.join(HERE, "qwen35_chat.c"),
                             os.path.join(HERE, "qwen35_tok.c"),
                             os.path.join(HERE, "qwen35_unicode_data.c"),
                             os.path.join(HERE, "tests", "chat_batch.c"))
                 if os.path.getmtime(f) > os.path.getmtime(cbin)]
        if newer:
            raise SystemExit(
                "%s is older than %s.\n"
                "  Re-run with --build.  A stale binary reports a FAIL that "
                "belongs to a source nobody is looking at."
                % (cbin, ", ".join(os.path.basename(f) for f in newer)))

    cases = build_cases(a.seed, a.n_random)
    print(f"cases             : {len(cases)} "
          f"({len(cases) - a.n_random} hand-written, {a.n_random} random)")

    tmpl = make_env(load_template(a.qtk, a.jinja))
    ours = run_c(cbin, cases, a.qtk if a.ids else None)

    n_ok = n_refused_both = 0
    deliberate = []
    bad_bytes, bad_refuse, bad_accept = [], [], []
    ids_pairs = []

    for i, ((msgs, agp, think), (rc, txt, ids)) in enumerate(zip(cases, ours)):
        want, err = render_oracle(tmpl, msgs, agp, think)
        if rc < 0:
            if err is not None:
                n_refused_both += 1
            elif rc in DELIBERATE:
                deliberate.append((i, E.get(rc, rc), msgs))
            else:
                # We refused something the template renders and that is NOT on
                # the documented out-of-scope list.  A coverage regression.
                bad_refuse.append((i, E.get(rc, rc), msgs, want))
            continue
        if err is not None:
            bad_accept.append((i, msgs, err, txt))
            continue
        if txt == want.encode("utf-8"):
            n_ok += 1
            if a.ids:
                ids_pairs.append((i, want.encode("utf-8"), ids))
        else:
            bad_bytes.append((i, msgs, agp, think, want.encode("utf-8"), txt))

    print(f"leg 1 bytes       : {n_ok} identical, {len(bad_bytes)} DIFFER")
    print(f"      refusals     : {n_refused_both} refused by both, "
          f"{len(deliberate)} deliberately out of scope, "
          f"{len(bad_refuse)} refused by C only, {len(bad_accept)} accepted by C only")
    for i, code, msgs in deliberate[:a.show]:
        print(f"    deliberate  case {i}: {code}  msgs={msgs}")

    for i, msgs, agp, think, w, g in bad_bytes[:a.show]:
        print(f"  case {i}: agp={agp} think={think} msgs={msgs}")
        print(f"    jinja2 : {show(w)}")
        print(f"    C      : {show(g)}")
        for k in range(min(len(w), len(g))):
            if w[k] != g[k]:
                print(f"    first difference at byte {k}: "
                      f"{w[k:k+12]!r} vs {g[k:k+12]!r}")
                break
        else:
            print(f"    identical prefix, lengths {len(w)} vs {len(g)}")
    for i, code, msgs, want in bad_refuse[:a.show]:
        print(f"  case {i}: C refused ({code}) but the template renders it: msgs={msgs}")
        print(f"    jinja2 : {show(want.encode('utf-8'))}")
    for i, msgs, err, txt in bad_accept[:a.show]:
        print(f"  case {i}: C accepted but the template raised: {err}")
        print(f"    msgs   : {msgs}")
        print(f"    C      : {show(txt)}")

    ids_bad = 0
    if a.ids:
        if not os.path.exists(a.oracle):
            print(f"leg 2 ids         : SKIPPED, no oracle at {a.oracle}")
        elif not os.path.exists(a.gguf):
            print(f"leg 2 ids         : SKIPPED, no gguf at {a.gguf}")
        else:
            texts = [t for _, t, _ in ids_pairs]
            theirs = run_llamacpp(a.oracle, a.gguf, texts)
            for (i, t, mine), yours in zip(ids_pairs, theirs):
                if mine != yours:
                    ids_bad += 1
                    if ids_bad <= a.show:
                        print(f"  case {i}: ids differ, {len(mine)} vs {len(yours)}")
                        print(f"    text  : {show(t)}")
                        for k in range(min(len(mine), len(yours))):
                            if mine[k] != yours[k]:
                                print(f"    first at {k}: {mine[k:k+8]} vs {yours[k:k+8]}")
                                break
            print(f"leg 2 ids         : {len(texts) - ids_bad} identical, "
                  f"{ids_bad} DIFFER (oracle = llama.cpp)")

    failed = bool(bad_bytes or bad_refuse or bad_accept or ids_bad)
    if a.mutate:
        # Under a mutation the comparison MUST fail.  A mutation that does not
        # bite is reported by name and is the most useful line here: it is the
        # resolution floor of the check.
        print(f"\nMUTATION {a.mutate}: "
              f"{'BITES (comparison failed, as required)' if failed else 'DOES NOT BITE'}")
        return 0 if failed else 1

    print(f"\nCHAT_TEMPLATE {'FAIL' if failed else 'PASS'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
