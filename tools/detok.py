#!/usr/bin/env python3
"""detok.py -- turn the PL engine's token ids into text.

The llama_engine_axi core hands the PS a list of token ids (AXI 0x40+4i).  This
maps them back through the same llama2.c tokenizer the C oracle uses
(ref/tok512.bin) so a hardware run can be read as a story.

  usage:  detok.py 403 407 261 378 ...
          devmem-dump | detok.py --stdin

tok512.bin layout (llama2.c export): int32 max_token_length, then vocab_size
records of {float32 score, int32 len, len bytes}.
"""
import struct
import sys
import os

TOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ref", "tok512.bin")
VOCAB = 512


def load_vocab(path=TOK):
    return _load(path)[0]


def _load(path=TOK):
    with open(path, "rb") as f:
        blob = f.read()
    off = 4  # skip max_token_length
    words, scores = [], []
    for _ in range(VOCAB):
        (sc,) = struct.unpack_from("<f", blob, off); off += 4
        (ln,) = struct.unpack_from("<i", blob, off); off += 4
        words.append(blob[off:off + ln]); off += ln
        scores.append(sc)
    return words, scores


def encode(text, path=TOK, bos=True):
    """llama2.c encode(): sentencepiece BPE over the same tok512.bin the C oracle
    uses.  Byte-fallback tokens are ids 3..258 (byte + 3).  Returns token ids."""
    words, scores = _load(path)
    lookup = {w: i for i, w in enumerate(words)}

    toks = [1] if bos else []
    if text:
        # sentencepiece prepends a space to the first real piece
        text = " " + text.lstrip(" ") if not text.startswith(" ") else text
    # start from single UTF-8 characters, falling back to raw bytes
    pieces = []
    for ch in text:
        b = ch.encode("utf-8")
        if b in lookup:
            pieces.append(lookup[b])
        else:
            pieces.extend(by + 3 for by in b)   # byte fallback
    # greedily apply the highest-scoring adjacent merge until none apply
    while True:
        best_score, best_at, best_id = -1e10, -1, -1
        for i in range(len(pieces) - 1):
            merged = words[pieces[i]] + words[pieces[i + 1]]
            j = lookup.get(merged)
            if j is not None and scores[j] > best_score:
                best_score, best_at, best_id = scores[j], i, j
        if best_at < 0:
            break
        pieces[best_at:best_at + 2] = [best_id]
    return toks + pieces


def decode(ids, words):
    """Mirror llama2.c decode(): strip the leading space on the token that
    follows BOS(1), and expand <0xXX> byte-fallback tokens."""
    out = bytearray()
    prev = None
    for t in ids:
        if t == 1:                      # BOS emits nothing
            prev = t
            continue
        piece = words[t]
        if prev == 1 and piece.startswith(b" "):
            piece = piece[1:]
        if len(piece) == 6 and piece.startswith(b"<0x") and piece.endswith(b">"):
            out.append(int(piece[3:5], 16))
        else:
            out += piece
        prev = t
    return out.decode("utf-8", errors="replace")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] == "--stdin":
        args = sys.stdin.read().split()
    ids = [int(a, 0) for a in args if a.strip().lstrip("-").replace("x", "").isalnum()]
    words = load_vocab()
    print(decode(ids, words))
