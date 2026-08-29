#!/usr/bin/env python3
"""Check tools/qwen35_tokenizer.py against llama.cpp, bit for bit.

THE ORACLE is llama.cpp's own vocabulary code, reached through
tools/tok_oracle_batch.cpp (a ~120-line shim over llama_tokenize /
llama_detokenize, vocab_only, no GPU).  It is an independent implementation:
different language, different author, different data structures, reading the
same GGUF.

A ROUND TRIP IS NOT AN ORACLE.  encode-then-decode agreeing with itself proves
only self-consistency, which a wrong-but-consistent implementation also has.
Both directions here are compared against llama.cpp, never against ourselves.

Build the oracle first:
    g++ -O2 -std=c++17 tools/tok_oracle_batch.cpp -o build_artifacts_tok/tok_oracle_batch \
        -I$HOME/GitHub/llama.cpp.upstream/include \
        -I$HOME/GitHub/llama.cpp.upstream/ggml/include \
        -L$HOME/GitHub/llama.cpp.upstream/build/bin -lllama \
        -Wl,-rpath,$HOME/GitHub/llama.cpp.upstream/build/bin

Then:
    verify_tokenizer.py --qtk build_artifacts_tok/qwen35_9b.qtk \
        --gguf /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
        --oracle build_artifacts_tok/tok_oracle_batch

--mutate NAME deliberately breaks the encoder to prove the comparison has
teeth.  A checker never shown to fail has not been shown to work.
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qwen35_tokenizer import Qwen35Tokenizer, ATTR_CONTROL   # noqa: E402


# ------------------------------------------------------------------- corpus

CJK = "你好世界，这是一个测试。日本語のテキストもあります。한국어 텍스트입니다。"
EMOJI = "\U0001F600\U0001F1FA\U0001F1F8\U0001F469‍\U0001F4BB\U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F❤️"
COMBINING = "é à́ ñ ȫ क्ष กำ A̴̵̶̷"
RTL = "السلام عليكم שָׁלוֹם"

CODE = '''\
def f(x, y=3, *args, **kw):
\t"""Doc."""
\tif x <= y and (x != 0):
\t\treturn [i**2 for i in range(x)]   # trailing comment
\treturn {"a": 1, 'b': None}

class A(B):
    @property
    def z(self) -> "int|None":
        return self._z or 0xDEADBEEF
'''

VHDL = '''\
architecture rtl of foo is
  signal s : std_logic_vector(31 downto 0) := (others => '0');
begin
  p : process(clk) begin
    if rising_edge(clk) then s <= s(30 downto 0) & '1'; end if;
  end process;
end architecture;
'''

PROSE = ("The quick brown fox jumps over the lazy dog. It's a test; isn't it? "
         "She'd say they've won -- we'll see. 3.14159, 42, 1e-9, 0x1F, 1,000,000.")

SPECIALS_TEXT = [
    "<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n",
    "<think>reasoning</think>answer",
    "<tool_call>{\"name\": \"f\"}</tool_call>",
    "<|endoftext|>",
    "a<|im_end|><|im_start|>b",
    "<|im_start|",
    "<|im_start|><|im_start|>",
    "<|vision_start|><|image_pad|><|vision_end|>",
    "not a special <|nope|> here",
    "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>",
]

WHITESPACE_CASES = [
    "", " ", "  ", "   ", "\t", "\n", "\r\n", "\r", "\n\n\n", " \n ", "\n ",
    " a", "a ", "  a  ", "a\n", "\na", "a \n b", "a\t\tb", "a  \n\n  b",
    "   \t \n \t   ", " ", "  ", "a b", "　", "a　b",
    "\u2028", "\u2029", "\x0b", "\x0c", "\x85", " \u200b ",
    "hello   world", "hello\n\n\nworld", "trailing   ", "   leading",
]

EDGE_CASES = [
    "'s", "'S", "'t", "'RE", "'ve", "'M", "'ll", "'LL", "'d", "'D",
    "don't", "DON'T", "it’s", "y'all'd've",
    "'", "''", "'''", "a'", "'a", "' s",
    "0", "00", "000", "1234567890", "a1b2c3", "12.34", "1_000",
    "٠١٢", "一二三", "ⅠⅡ", "½", "⁵",
    "!!!", "...", "?!", "---", "===", "\\\\", "//", "/*", "*/",
    "́", "́́", "á", "́a", " ́", "́ ",
    "‍", "​", "﻿", "�",
    "\U0001F600", "\U0001F600\U0001F600", "a\U0001F600b", " \U0001F600 ",
    "ſs", "ẞ", "ß", "İ",
    "\U000E0001", "\U000F0000", "\U00100000",   # unassigned / private use
    "\x00", "a\x00b", "\x01\x02\x1f", "\x7f",
    "http://example.com/a?b=c&d=%20e#f",
    "a" * 300, " " * 64, "\n" * 32, "中" * 100,
]


def build_corpus(seed=1234, n_random=1500, repo_root=None):
    """Return the list of strings to compare.  Deterministic given seed."""
    rng = random.Random(seed)
    corpus = []

    corpus += WHITESPACE_CASES
    corpus += EDGE_CASES
    corpus += SPECIALS_TEXT
    corpus += [PROSE, CODE, VHDL, CJK, EMOJI, COMBINING, RTL]

    # every prose/code/CJK sample also with each whitespace decoration
    for base in (PROSE, CODE[:200], CJK, EMOJI, COMBINING, RTL):
        for deco in ("", " ", "  ", "\n", "\t", "\r\n"):
            corpus.append(deco + base)
            corpus.append(base + deco)
            corpus.append(deco + base + deco)

    # real source text from the repo: exercises indentation and punctuation
    if repo_root:
        picks = []
        for sub, exts in (("rtl", (".vhd",)), ("ref", (".c", ".h")),
                          ("tools", (".py",)), ("docs", (".md",)),
                          ("server", (".cpp",))):
            d = os.path.join(repo_root, sub)
            if not os.path.isdir(d):
                continue
            for root, _dirs, files in os.walk(d):
                for fn in sorted(files):
                    if fn.endswith(exts):
                        picks.append(os.path.join(root, fn))
                break
        rng.shuffle(picks)
        for p in picks[:40]:
            try:
                with open(p, "rb") as f:
                    txt = f.read().decode("utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for _ in range(6):
                if len(txt) < 40:
                    break
                i = rng.randrange(0, max(1, len(txt) - 40))
                j = min(len(txt), i + rng.randrange(20, 600))
                corpus.append(txt[i:j])

    # random fuzz: mixed-script strings drawn from pools that stress the
    # letter / mark / number / punctuation / whitespace boundaries the
    # pre-tokenizer regex turns on.
    pools = [
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "0123456789",
        " \t\n\r",
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
        "àéîõüßçñ",
        "ً̧́̀̈ิ्",       # combining marks
        "一二三四五あいア한글",
        "\U0001F600\U0001F680\U0001F1FA\U0001F1F8❤️‍",
        "العربيةאבג",
        "    　  ",
        "٠١Ⅰ½⁵〇",
        "\x00\x01\x1f\x7f\x85\u200b\ufeff",
    ]
    for _ in range(n_random):
        k = rng.randrange(1, 8)
        chosen = [rng.choice(pools) for _ in range(k)]
        s = "".join("".join(rng.choice(p) for _ in range(rng.randrange(1, 12)))
                    for p in chosen)
        corpus.append(s)

    # random fuzz over raw codepoints, skipping surrogates (not encodable)
    for _ in range(n_random // 3):
        n = rng.randrange(1, 20)
        cps = []
        while len(cps) < n:
            cp = rng.randrange(0x0, 0x2FFFF)
            if 0xD800 <= cp <= 0xDFFF:
                continue
            cps.append(chr(cp))
        corpus.append("".join(cps))

    # special tokens embedded in random surroundings
    sp = ["<|im_start|>", "<|im_end|>", "<think>", "</think>", "<tool_call>",
          "<|endoftext|>", "<|vision_pad|>", "<tts_pad>", "<|fim_pad|>"]
    for _ in range(200):
        parts = []
        for _ in range(rng.randrange(1, 5)):
            parts.append(rng.choice(sp))
            parts.append("".join(rng.choice("abc 12\n一́") for _ in range(rng.randrange(0, 8))))
        corpus.append("".join(parts))

    # dedupe, keep order
    seen = set()
    out = []
    for s in corpus:
        if s in seen:
            continue
        seen.add(s)
        out.append(s)
    return out


# ------------------------------------------------------------------- oracle

def run_oracle(oracle, gguf, texts, id_lists=None, parse_special=True, add_special=False):
    """One process, one vocab load, all items."""
    args = [oracle, gguf]
    if not parse_special:
        args.append("--no-parse-special")
    if add_special:
        args.append("--add-special")
    if id_lists is not None:
        args.append("--detok")

    payload = bytearray()
    payload += struct.pack("<I", len(texts))
    for t in texts:
        b = t.encode("utf-8")
        payload += struct.pack("<I", len(b)) + b
    if id_lists is not None:
        payload += struct.pack("<I", len(id_lists))
        for ids in id_lists:
            payload += struct.pack("<I", len(ids))
            payload += struct.pack(f"<{len(ids)}i", *ids) if ids else b""

    p = subprocess.run(args, input=bytes(payload), stdout=subprocess.PIPE)
    if p.returncode != 0:
        raise SystemExit(f"oracle exited {p.returncode}")
    buf = p.stdout
    pos = 0

    def u32():
        nonlocal pos
        v = struct.unpack_from("<I", buf, pos)[0]
        pos += 4
        return v

    enc = []
    for _ in range(len(texts)):
        k = u32()
        enc.append(list(struct.unpack_from(f"<{k}i", buf, pos)) if k else [])
        pos += 4 * k

    det = None
    if id_lists is not None:
        det = []
        for _ in range(len(id_lists)):
            m = u32()
            det.append(buf[pos:pos + m])
            pos += m
    return enc, det


# ------------------------------------------------------------------ mutation

def apply_mutation(tk, name):
    """Deliberately break the encoder.  Returns a human description."""
    if name == "merge-rank":
        # Perturb ONE rank: demote the space+t merge, rank 3, to last.  It is
        # named explicitly rather than picked by position because three
        # plausible automatic choices all turn out to be NO-OPS, and a mutation
        # that cannot change an output tests nothing:
        #   * a mid-table swap perturbs merges no corpus contains
        #     (--mutate merge-rank-mid, kept, still passes);
        #   * swapping ranks 0 and 1 perturbs ('G','G') and ('GG','GG') -- the
        #     second cannot exist until the first has fired, so their relative
        #     order is unobservable (--mutate merge-rank-01, kept, passes);
        #   * swapping the first "competing" pair found by scanning also lands
        #     on ('G','G') vs ('G','t') and changes nothing measurable.
        key = ("Ġ", "t")            # 'G-with-dot' is byte 0x20 in the GPT-2 map
        if key not in tk.bpe_ranks:
            raise SystemExit(f"merge-rank: {key!r} is not in this merge table")
        old = tk.bpe_ranks[key]
        tk.bpe_ranks[key] = len(tk.bpe_ranks)
        return f"demoted merge {key!r} from rank {old} to rank {len(tk.bpe_ranks)} (last)"
    if name == "merge-rank-01":
        # KEPT DELIBERATELY, AND IT PASSES.  See merge-rank.
        items = sorted(tk.bpe_ranks.items(), key=lambda kv: kv[1])
        (ka, ra), (kb, rb) = items[0], items[1]
        tk.bpe_ranks[ka], tk.bpe_ranks[kb] = rb, ra
        return (f"swapped merge ranks {ra}<->{rb} for {ka!r} and {kb!r} "
                f"(expected to be toothless)")
    if name == "merge-rank-mid":
        # KEPT DELIBERATELY, AND IT PASSES.  Swapping two adjacent ranks in the
        # middle of a 247587-entry table perturbs merges that no realistic
        # corpus contains, so the comparison sees nothing.  A mutation that
        # passes is a statement about the mutation, not about the checker.
        items = sorted(tk.bpe_ranks.items(), key=lambda kv: kv[1])
        i = len(items) // 2
        (ka, ra), (kb, rb) = items[i], items[i + 1]
        tk.bpe_ranks[ka], tk.bpe_ranks[kb] = rb, ra
        return f"swapped merge ranks {ra}<->{rb} for {ka!r} and {kb!r} (expected to be toothless)"
    if name == "decode-special":
        # break the DECODER only: stop rendering CONTROL tokens as their text
        orig = tk.piece_bytes
        tk.piece_bytes = lambda tid, render_special=True: (
            b"" if tk.token_type[tid] == ATTR_CONTROL else orig(tid, render_special))
        return "decoder no longer renders CONTROL tokens (e.g. <|im_end|>) as text"
    if name == "decode-bytemap":
        # break the DECODER only: one wrong entry in the inverse byte map
        import qwen35_tokenizer as q
        old = q.UNI_TO_BYTE["Ġ"]
        q.UNI_TO_BYTE["Ġ"] = 0x21
        return f"inverse byte map: U+0120 now decodes to 0x21, was 0x{old:02X}"
    if name == "drop-special":
        # forget that <|im_start|> is a special token
        sid = tk.token_to_id["<|im_start|>"]
        tk.special_ids = [i for i in tk.special_ids if i != sid]
        return f"removed <|im_start|> (id {sid}) from the special-token partition set"
    if name == "qwen2-regex":
        # use the qwen2 pre-tokenizer pattern instead of the qwen35 one
        import qwen35_tokenizer as q
        import regex as _re
        pat = (r"(?i:'s|'t|'re|'ve|'m|'ll|'d)"
               r"|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*"
               r"|\s*[\r\n]+|\s+(?!\S)|\s+")
        tk._split = lambda t: [m.group(0) for m in _re.finditer(pat, t) if m.group(0)]
        del q
        return "replaced the qwen35 pre-tokenizer pattern with the qwen2 one (no \\p{M})"
    if name == "byte-map":
        # perturb one entry of the GPT-2 byte map
        import qwen35_tokenizer as q
        old = q.BYTE_TO_UNI[0x20]
        q.BYTE_TO_UNI[0x20] = q.BYTE_TO_UNI[0x21]
        return f"remapped byte 0x20 from {old!r} to {q.BYTE_TO_UNI[0x20]!r}"
    raise SystemExit(f"unknown mutation {name!r}")


# --------------------------------------------------------------------- main

def sweep_codepoints(a):
    """Compare on every codepoint in U+0000..U+10FFFF, minus surrogates.

    The corpus catches what a corpus contains.  The pre-tokenizer's behaviour
    is a function of each codepoint's Unicode category, and there are 1112064
    of those, so the category decisions can simply be enumerated instead of
    sampled.  Two contexts are enough to expose them: "a<c>b" puts the
    codepoint next to letters, " <c>1" next to a space and a digit.

    This is how the Unicode-version skew documented in
    docs/debugging/2026-08-28_qwen35-tokenizer.md was found: 4704 codepoints,
    all Cn under this interpreter's Unicode 13.0.0, that llama.cpp's newer
    tables classify differently.  The corpus had found only 4 of them.
    """
    tk = Qwen35Tokenizer(a.qtk, split=a.split)
    if a.mutate:
        print(f"MUTATION APPLIED  : {apply_mutation(tk, a.mutate)}")
    cps = [c for c in range(0x110000) if not (0xD800 <= c <= 0xDFFF)]
    ctxs = ("a{}b", " {}1")
    bad = []
    CH = 200000
    for s in range(0, len(cps), CH):
        chunk = cps[s:s + CH]
        texts, meta = [], []
        for cp in chunk:
            c = chr(cp)
            for f in ctxs:
                texts.append(f.format(c))
                meta.append(cp)
        theirs, _ = run_oracle(a.oracle, a.gguf, texts)
        for i, t in enumerate(texts):
            if tk.encode(t) != theirs[i]:
                bad.append(meta[i])
        print(f"  ..{s + len(chunk)}/{len(cps)} divergent so far: {len(set(bad))}", flush=True)

    bad = sorted(set(bad))
    print(f"\nsplit backend     : {a.split}")
    print(f"codepoints swept  : {len(cps)}  (x{len(ctxs)} contexts = {len(cps) * len(ctxs)} strings)")
    print(f"divergent         : {len(bad)}")
    for cp in bad[:a.max_report]:
        try:
            nm = unicodedata.name(chr(cp))
        except ValueError:
            nm = "<unnamed>"
        print(f"   U+{cp:04X} cat={unicodedata.category(chr(cp))} {nm}")
    if len(bad) > a.max_report:
        print(f"   ... {len(bad) - a.max_report} more")
    print(f"\nRESULT: {'PASS' if not bad else 'FAIL'}")
    return 0 if not bad else 1


def show(s, n=90):
    r = repr(s)
    return r if len(r) <= n else r[:n - 3] + "..."


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qtk", required=True)
    ap.add_argument("--gguf", required=True)
    ap.add_argument("--oracle", default="build_artifacts_tok/tok_oracle_batch")
    ap.add_argument("--split", default="regex", choices=("regex", "llamacpp"))
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--n-random", type=int, default=1500)
    ap.add_argument("--repo-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--mutate", help="break the tokenizer on purpose: merge-rank | "
                                     "merge-rank-mid | merge-rank-01 | drop-special | qwen2-regex | "
                                     "byte-map | decode-special | decode-bytemap")
    ap.add_argument("--max-report", type=int, default=12)
    ap.add_argument("--no-detok", action="store_true")
    ap.add_argument("--all-ids", action="store_true",
                    help="also decode EVERY id in the vocabulary, one per "
                         "string, and compare against the oracle.  The corpus "
                         "can only reach ids that encoding produces, so any "
                         "token unreachable from text -- UNUSED padding above "
                         "all -- is invisible to it at any corpus size.  That "
                         "is not hypothetical: it hid a real decoder bug on "
                         "243 of 248,320 ids until the C port found it.")
    ap.add_argument("--sweep-codepoints", action="store_true",
                    help="instead of the corpus, put EVERY Unicode codepoint through two "
                         "contexts and compare.  Exhaustive over the pre-tokenizer's "
                         "category decisions; ~2.2M strings, a few minutes.")
    a = ap.parse_args()

    if a.sweep_codepoints:
        return sweep_codepoints(a)

    corpus = build_corpus(a.seed, a.n_random, a.repo_root)
    print(f"corpus            : {len(corpus)} strings, "
          f"{sum(len(s.encode('utf-8')) for s in corpus)} UTF-8 bytes")
    print(f"split backend     : {a.split}")

    tk = Qwen35Tokenizer(a.qtk, split=a.split)
    if a.mutate:
        desc = apply_mutation(tk, a.mutate)
        print(f"MUTATION APPLIED  : {desc}")

    mine = [tk.encode(s, parse_special=True) for s in corpus]

    # pass 1: the oracle's own encoding of the same corpus
    theirs, _ = run_oracle(a.oracle, a.gguf, corpus, parse_special=True)

    # pass 2: the oracle's detokenization of the ORACLE's ids.  Feeding it our
    # ids instead would compare our decoder against our encoder for anything we
    # got wrong, which is the self-consistency trap this file exists to avoid.
    det = None
    if not a.no_detok:
        _, det = run_oracle(a.oracle, a.gguf, corpus, id_lists=theirs, parse_special=True)

    enc_bad = [i for i in range(len(corpus)) if mine[i] != theirs[i]]
    print(f"encode compared   : {len(corpus)}")
    print(f"encode mismatches : {len(enc_bad)}")
    for i in enc_bad[:a.max_report]:
        print(f"  [{i}] text={show(corpus[i])}")
        print(f"       ours  ={mine[i][:40]}{' ...' if len(mine[i]) > 40 else ''}")
        print(f"       oracle={theirs[i][:40]}{' ...' if len(theirs[i]) > 40 else ''}")
    if len(enc_bad) > a.max_report:
        print(f"  ... {len(enc_bad) - a.max_report} more")

    dec_bad = []
    if not a.no_detok:
        for i in range(len(corpus)):
            ours = tk.decode_bytes(theirs[i], render_special=True)
            if ours != det[i]:
                dec_bad.append(i)
        print(f"decode compared   : {len(corpus)}")
        print(f"decode mismatches : {len(dec_bad)}")
        for i in dec_bad[:a.max_report]:
            print(f"  [{i}] ids={theirs[i][:20]}")
            print(f"       ours  ={show(tk.decode_bytes(theirs[i]))}")
            print(f"       oracle={show(det[i])}")

    # Every id, individually.  See --all-ids: the corpus reaches only ids that
    # encoding produces, so this is the ONLY check here that can see a token
    # unreachable from text.
    ids_bad = []
    if a.all_ids:
        n = len(tk.tokens)
        singles = [[i] for i in range(n)]
        _, det_all = run_oracle(a.oracle, a.gguf, [""] * n,
                                id_lists=singles, parse_special=True)
        for i in range(n):
            if tk.decode_bytes([i], render_special=True) != det_all[i]:
                ids_bad.append(i)
        print(f"token ids compared: {n}")
        print(f"id mismatches     : {len(ids_bad)}")
        for i in ids_bad[:a.max_report]:
            print(f"  [{i}] tok={show(tk.tokens[i])} type={tk.token_type[i]}")
            print(f"       ours  ={show(tk.decode_bytes([i]))}")
            print(f"       oracle={show(det_all[i])}")
        if len(ids_bad) > a.max_report:
            print(f"  ... {len(ids_bad) - a.max_report} more")

    total_bad = len(enc_bad) + len(dec_bad) + len(ids_bad)
    print(f"\nRESULT: {'PASS' if total_bad == 0 else 'FAIL'} "
          f"({total_bad} mismatch{'' if total_bad == 1 else 'es'} over "
          f"{len(corpus)} strings x {'2' if not a.no_detok else '1'} directions)")
    return 0 if total_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
