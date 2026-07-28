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
    with open(path, "rb") as f:
        blob = f.read()
    off = 4  # skip max_token_length
    words = []
    for _ in range(VOCAB):
        (_score,) = struct.unpack_from("<f", blob, off); off += 4
        (ln,) = struct.unpack_from("<i", blob, off); off += 4
        words.append(blob[off:off + ln]); off += ln
    return words


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
