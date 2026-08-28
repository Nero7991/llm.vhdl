#!/usr/bin/env python3
"""Byte-level BPE encode/decode for the Qwen3.5 vocabulary.

Reads the artefact written by tools/extract_tokenizer.py and reproduces what
llama.cpp does for tokenizer.ggml.model == "gpt2" with
tokenizer.ggml.pre == "qwen35".  Verified bit-exactly against llama.cpp itself
by tools/verify_tokenizer.py; see docs/debugging/2026-08-28_qwen35-tokenizer.md
for the corpus and the numbers.

PIPELINE, in order.  Each stage names the llama.cpp function it mirrors.

  1. special-token partition   llama_vocab::impl::tokenizer_st_partition
     The raw text is cut on literal occurrences of any token whose token_type
     is CONTROL, USER_DEFINED or UNKNOWN.  Specials are tried longest-text
     first.  Only reached when parse_special is on; llama-tokenize defaults it
     on, so an "<|im_start|>" typed by a user really does become token 248045.

  2. pre-tokenizer split       unicode_regex_split / ..._custom_qwen35
     Each non-special fragment is cut into words by

       (?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+|\p{N}
       | ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+

     This is the qwen35 pattern, and it is NOT the qwen2 one: qwen2 has
     `\p{L}+` and ` ?[^\s\p{L}\p{N}]+`, qwen35 admits \p{M} (combining marks)
     into the letter run and excludes it from the punctuation run.  Using the
     qwen2 pattern here mis-splits every decomposed accent.

     Two backends are implemented and both are checked against the oracle:
       "regex"    -- the pattern above, run by the third-party `regex` module.
                     This is the NORMATIVE form, the one in the HF
                     tokenizer.json the model was trained with.
       "llamacpp" -- a transcription of llama.cpp's hand-written state machine
                     unicode_regex_split_custom_qwen35(), which is what the
                     oracle actually executes.  Kept so that a disagreement can
                     be attributed to regex semantics rather than to us.

  3. byte encoding             unicode_byte_encoding_process
     Each word's raw bytes are mapped through the GPT-2 bytes-to-unicode table,
     so every byte becomes exactly one codepoint and no vocabulary entry ever
     contains a raw control byte.

  4. BPE                       llm_tokenizer_bpe_session::tokenize
     Symbols start as one codepoint each.  A priority queue holds every
     adjacent pair that has a merge rank, ordered by (rank asc, left index
     asc), and pops until empty.  Popped pairs whose text no longer matches the
     current symbols are stale and skipped.  This is llama.cpp's exact
     algorithm, not the "scan for the min-rank pair each round" formulation;
     they agree, but transcribing the one the oracle runs removes a class of
     doubt.

  5. vocabulary lookup
     A merged symbol not in the vocabulary is emitted byte by byte, dropping
     bytes that have no token.  For this vocab that path is unreachable (all
     256 byte-mapped characters are present), but it is kept because llama.cpp
     has it.

WHAT THIS DOES NOT DO.  add_bos / add_eos.  The GGUF carries no
tokenizer.ggml.add_bos_token key and no BOS id, and llama.cpp's BPE branch
leaves add_bos false, so nothing is prepended.  A caller that wants EOS appends
token 248046 itself.

A C PORT WILL BE NEEDED.  server/llama_server.cpp is zero-dep C++ and cannot
call into Python.  Everything here is portable: the only non-trivial data are
the Unicode letter/mark/number/whitespace category tables that step 2 needs,
which is exactly why llama.cpp ships its own generated unicode-data.cpp.  A C
port should transcribe the "llamacpp" backend, not the regex one.

Usage:
    qwen35_tokenizer.py TOK.qtk --encode "text"
    qwen35_tokenizer.py TOK.qtk --decode "1,2,3"
    qwen35_tokenizer.py TOK.qtk --encode-file FILE
"""

import argparse
import heapq
import sys
import unicodedata

try:
    import regex as _regex
except ImportError:                                   # pragma: no cover
    _regex = None

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from extract_tokenizer import read_qtk                # noqa: E402

# token_type values that make a token "special" for partitioning purposes,
# matching llama.cpp's LLAMA_TOKEN_ATTR_{UNKNOWN,CONTROL,USER_DEFINED}
ATTR_UNKNOWN, ATTR_CONTROL, ATTR_USER_DEFINED = 2, 3, 4
SPECIAL_ATTRS = (ATTR_UNKNOWN, ATTR_CONTROL, ATTR_USER_DEFINED)

# NORMATIVE pattern, from the HF tokenizer.json, quoted verbatim in
# llama.cpp src/llama-vocab.cpp under LLAMA_VOCAB_PRE_TYPE_QWEN35.
QWEN35_PATTERN = (
    r"(?i:'s|'t|'re|'ve|'m|'ll|'d)"
    r"|[^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+"
    r"|\p{N}"
    r"| ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*"
    r"|\s*[\r\n]+"
    r"|\s+(?!\S)"
    r"|\s+"
)


# --------------------------------------------------------------- byte mapping

def _bytes_to_unicode():
    """GPT-2's reversible byte<->codepoint table (unicode_byte_to_utf8_map)."""
    bs = list(range(0x21, 0x7E + 1)) + list(range(0xA1, 0xAC + 1)) + list(range(0xAE, 0xFF + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return {b: chr(c) for b, c in zip(bs, cs)}


BYTE_TO_UNI = _bytes_to_unicode()
UNI_TO_BYTE = {v: k for k, v in BYTE_TO_UNI.items()}


# ------------------------------------------------- llama.cpp category helpers
#
# llama.cpp classifies each codepoint with unicode_cpt_flags_from_cpt(), backed
# by the tables scripts/gen-unicode-data.py builds from the CURRENT UnicodeData
# .txt it downloads.  Two things about that matter here and both were found the
# hard way (see docs/debugging/2026-08-28_qwen35-tokenizer.md):
#
#   * the table is newer than this interpreter's.  Python 3.10's unicodedata is
#     Unicode 13.0.0; llama.cpp's is whatever was current at build time, and
#     4704 codepoints (e.g. U+0870 ARABIC LETTER ALEF WITH ATTACHED FATHA) are
#     letters there and Cn here.  The third-party `regex` module ships its own,
#     newer tables that DO agree, so categories come from `regex` when it is
#     available and fall back to unicodedata otherwise.
#
#   * Cn is not "no flags".  gen-unicode-data.py maps Cn to
#     CODEPOINT_FLAG_UNDEFINED = 0x0001, so flags.as_uint() is non-zero for
#     EVERY codepoint.  The only zero-flag value is the sentinel the splitter
#     returns for an out-of-range index.  _has_flags therefore answers "is this
#     position inside the string", not "is this codepoint assigned".

def _cat_matcher(pattern):
    if _regex is not None:
        rx = _regex.compile(pattern)
        return lambda c: rx.match(c) is not None
    return None


_RX_L = _cat_matcher(r"\p{L}")
_RX_M = _cat_matcher(r"\p{M}")
_RX_N = _cat_matcher(r"\p{N}")


def _is_letter(cp):
    return _RX_L(cp) if _RX_L else unicodedata.category(cp)[0] == "L"


def _is_mark(cp):
    return _RX_M(cp) if _RX_M else unicodedata.category(cp)[0] == "M"


def _is_number(cp):
    return _RX_N(cp) if _RX_N else unicodedata.category(cp)[0] == "N"


# gen-unicode-data.py's table_whitespace, verbatim: Unicode White_Space.  It is
# an explicit list, NOT category Z, because \t \n \v \f \r are Cc.
_WS = (set(range(0x09, 0x0D + 1)) | set(range(0x2000, 0x200A + 1)) |
       {0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000})


def _is_whitespace(cp):
    return ord(cp) in _WS


def _has_flags(cp):
    """llama.cpp's flags.as_uint() != 0.  True for every real codepoint."""
    return cp is not None


# ------------------------------------------------------- pre-tokenizer splits

def _split_regex(text):
    if _regex is None:
        raise RuntimeError("the `regex` module is required for the 'regex' split backend")
    return [m.group(0) for m in _regex.finditer(QWEN35_PATTERN, text) if m.group(0)]


def _split_llamacpp(text):
    """Transcription of unicode_regex_split_custom_qwen35() in src/unicode.cpp.

    Operates on a list of codepoints, emitting word boundaries.  Deliberately
    keeps the C++ control flow, including the parts that are not what the
    regex literally means (see the comment on the letter branch below).
    """
    cpts = list(text)
    n = len(cpts)
    out = []
    prev_end = 0

    def cpt(i):
        return cpts[i] if 0 <= i < n else None

    def add(end):
        nonlocal prev_end
        if end > prev_end:
            out.append("".join(cpts[prev_end:end]))
        prev_end = end

    pos = 0
    while pos < n:
        c = cpts[pos]

        # regex: (?i:'s|'t|'re|'ve|'m|'ll|'d)
        if c == "'" and pos + 1 < n:
            c1 = cpts[pos + 1].lower()
            if c1 in ("s", "t", "m", "d"):
                add(pos + 2)
                pos += 2
                continue
            if pos + 2 < n:
                c2 = cpts[pos + 2].lower()
                if (c1, c2) in (("r", "e"), ("v", "e"), ("l", "l")):
                    add(pos + 3)
                    pos += 3
                    continue

        # regex: [^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+
        #
        # NOTE the C++ consumes the character at pos unconditionally once the
        # guard passes, so a leading mark is taken as the optional prefix and
        # then the run continues; a lone mark with no following letter/mark is
        # still emitted alone.  Kept as-is on purpose.
        if not (c in ("\r", "\n") or _is_number(c)):
            nxt = cpt(pos + 1)
            if (_is_letter(c) or _is_mark(c)
                    or (nxt is not None and (_is_mark(nxt) or _is_letter(nxt)))):
                pos += 1
                while pos < n and (_is_letter(cpts[pos]) or _is_mark(cpts[pos])):
                    pos += 1
                add(pos)
                continue

        # regex: \p{N}   (single digit, not runs)
        if _is_number(c):
            pos += 1
            add(pos)
            continue

        # regex: <space>?[^\s\p{L}\p{M}\p{N}]+[\r\n]*
        c2 = cpt(pos + 1) if c == " " else c
        def _punct(x):
            return (x is not None and _has_flags(x)
                    and not (_is_whitespace(x) or _is_letter(x) or _is_mark(x) or _is_number(x)))
        if _punct(c2) and _has_flags(c):
            if c == " ":
                pos += 1
            while _punct(cpt(pos)):
                pos += 1
            while cpt(pos) in ("\r", "\n"):
                pos += 1
            add(pos)
            continue

        # \s* [\r\n]+  /  \s+(?!\S)  /  \s+
        num_ws = 0
        last_nl = 0
        while pos + num_ws < n and _is_whitespace(cpts[pos + num_ws]):
            if cpts[pos + num_ws] in ("\r", "\n"):
                last_nl = pos + num_ws + 1
            num_ws += 1

        if last_nl > 0:
            pos = last_nl
            add(pos)
            continue
        if num_ws > 1 and pos + num_ws < n:
            pos += num_ws - 1
            add(pos)
            continue
        if num_ws > 0:
            pos += num_ws
            add(pos)
            continue

        pos += 1
        add(pos)

    return [w for w in out if w]


SPLITTERS = {"regex": _split_regex, "llamacpp": _split_llamacpp}


# ------------------------------------------------------------------ tokenizer

class Qwen35Tokenizer:
    def __init__(self, qtk_path, split="regex"):
        d = read_qtk(qtk_path)
        if d["model"] != "gpt2":
            raise ValueError(f"expected tokenizer.ggml.model == gpt2, got {d['model']!r}")
        if d["pre"] != "qwen35":
            raise ValueError(f"this file implements the qwen35 pre-tokenizer, "
                             f"the artefact says {d['pre']!r}")
        if split not in SPLITTERS:
            raise ValueError(f"split backend must be one of {sorted(SPLITTERS)}")

        self.split_name = split
        self._split = SPLITTERS[split]
        self.tokens = d["tokens"]
        self.token_type = d["token_type"]
        self.eos_token_id = d["eos_token_id"]
        self.pad_token_id = d["pad_token_id"]
        self.bos_token_id = d["bos_token_id"]
        self.add_bos = d["add_bos"]
        self.chat_template = d["chat_template"]

        self.token_to_id = {}
        for i, t in enumerate(self.tokens):
            # llama.cpp's token_to_id is built with operator[], so on a
            # duplicate text the LAST id wins.  Mirror that.
            self.token_to_id[t] = i

        # merge ranks.  A GGUF merge string is "A B"; A and B never contain a
        # space because they are byte-mapped (0x20 maps to U+0120).
        self.bpe_ranks = {}
        for rank, m in enumerate(d["merges"]):
            a, _, b = m.partition(" ")
            self.bpe_ranks[(a, b)] = rank

        # specials, longest text first (llama.cpp sorts by text.size() desc)
        specials = [i for i, tt in enumerate(self.token_type) if tt in SPECIAL_ATTRS]
        specials.sort(key=lambda i: (-len(self.tokens[i]), i))
        self.special_ids = specials
        self.special_texts = {i: self.tokens[i] for i in specials}

    # ------------------------------------------------------------ partition

    def _partition(self, text, parse_special=True):
        """List of (kind, payload): ('tok', id) or ('txt', str).

        Mirrors tokenizer_st_partition: for each special in longest-first
        order, walk the current fragment list and split every raw-text
        fragment on every literal occurrence.
        """
        frags = [("txt", text)] if text else []
        for sid in self.special_ids:
            if not parse_special and self.token_type[sid] in (ATTR_UNKNOWN, ATTR_CONTROL):
                continue
            stext = self.special_texts[sid]
            if not stext:
                continue
            out = []
            for kind, payload in frags:
                if kind != "txt":
                    out.append((kind, payload))
                    continue
                start = 0
                while True:
                    j = payload.find(stext, start)
                    if j < 0:
                        break
                    if j > start:
                        out.append(("txt", payload[start:j]))
                    out.append(("tok", sid))
                    start = j + len(stext)
                if start < len(payload):
                    out.append(("txt", payload[start:]))
            frags = out
        return frags

    # ------------------------------------------------------------------ bpe

    def _bpe_word(self, word):
        """word is already byte-mapped.  Returns a list of merged pieces."""
        syms = list(word)                       # one entry per byte-mapped char
        n = len(syms)
        if n == 0:
            return []
        prev = list(range(-1, n - 1))
        nxt = list(range(1, n + 1))
        nxt[-1] = -1

        heap = []                               # (rank, left, text)
        def push(l, r):
            if l == -1 or r == -1:
                return
            rank = self.bpe_ranks.get((syms[l], syms[r]))
            if rank is None:
                return
            heapq.heappush(heap, (rank, l, syms[l] + syms[r]))

        for i in range(1, n):
            push(i - 1, i)

        while heap:
            rank, l, text = heapq.heappop(heap)
            r = nxt[l]
            if r == -1 or not syms[l] or not syms[r]:
                continue
            if syms[l] + syms[r] != text:
                continue                        # stale entry
            syms[l] = syms[l] + syms[r]
            syms[r] = ""
            nxt[l] = nxt[r]
            if nxt[r] != -1:
                prev[nxt[r]] = l
            push(prev[l], l)
            push(l, nxt[l])

        return [s for s in syms if s]

    # --------------------------------------------------------------- encode

    def encode(self, text, parse_special=True, add_special=False):
        out = []
        if add_special and self.add_bos and self.bos_token_id is not None:
            out.append(self.bos_token_id)
        for kind, payload in self._partition(text, parse_special):
            if kind == "tok":
                out.append(payload)
                continue
            pieces = []
            for word in self._split(payload):
                mapped = "".join(BYTE_TO_UNI[b] for b in word.encode("utf-8"))
                pieces.extend(self._bpe_word(mapped))
            for p in pieces:
                tid = self.token_to_id.get(p)
                if tid is not None:
                    out.append(tid)
                else:
                    # llama.cpp's fallback: emit each byte-mapped char's own
                    # token, silently dropping any that has none.
                    for ch in p:
                        t = self.token_to_id.get(ch)
                        if t is not None:
                            out.append(t)
        return out

    # --------------------------------------------------------------- decode

    def piece_bytes(self, tid, render_special=True):
        """Raw bytes llama.cpp's token_to_piece would emit for one id."""
        tt = self.token_type[tid]
        if tt in (ATTR_UNKNOWN, ATTR_CONTROL):
            return self.tokens[tid].encode("utf-8") if render_special else b""
        if tt == ATTR_USER_DEFINED:
            return self.tokens[tid].encode("utf-8")
        # NORMAL and BYTE alike: undo the GPT-2 byte map, codepoint by codepoint
        return bytes(UNI_TO_BYTE[c] for c in self.tokens[tid] if c in UNI_TO_BYTE)

    def decode_bytes(self, ids, render_special=True):
        return b"".join(self.piece_bytes(i, render_special) for i in ids)

    def decode(self, ids, render_special=True, errors="replace"):
        return self.decode_bytes(ids, render_special).decode("utf-8", errors)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("qtk")
    ap.add_argument("--split", default="regex", choices=sorted(SPLITTERS))
    ap.add_argument("--encode")
    ap.add_argument("--encode-file")
    ap.add_argument("--decode", help="comma-separated token ids")
    ap.add_argument("--no-parse-special", action="store_true")
    a = ap.parse_args()

    tk = Qwen35Tokenizer(a.qtk, split=a.split)
    if a.encode is not None or a.encode_file is not None:
        if a.encode_file:
            with open(a.encode_file, "rb") as f:
                text = f.read().decode("utf-8")
        else:
            text = a.encode
        ids = tk.encode(text, parse_special=not a.no_parse_special)
        print(ids)
        print(" | ".join(repr(tk.decode([i])) for i in ids))
    if a.decode is not None:
        ids = [int(x) for x in a.decode.split(",") if x.strip()]
        sys.stdout.write(tk.decode(ids))
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
