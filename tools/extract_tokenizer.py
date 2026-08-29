#!/usr/bin/env python3
"""Pull the tokenizer out of a GGUF into a compact, C-loadable artefact.

The GGUF carries the whole tokenizer in metadata KV pairs, not in tensors:

    tokenizer.ggml.model        "gpt2"   -- byte-level BPE
    tokenizer.ggml.pre          "qwen35" -- which pre-tokenizer regex regime
    tokenizer.ggml.tokens       array of strings, index == token id
    tokenizer.ggml.token_type   array of int32, one per token (see TOKEN_TYPE)
    tokenizer.ggml.merges       array of "A B" strings, index == merge rank
    tokenizer.ggml.eos_token_id, tokenizer.ggml.padding_token_id
    tokenizer.chat_template     Jinja source

tools/pack_int4.py and tools/pack_model_fk33.py already parse this file's
header for TENSORS, via gguf-py's GGUFReader.  This reuses the same reader
rather than adding a second GGUF parser; the tensor path in those tools is
untouched.

OUTPUT.  One binary blob, little-endian, meant to be mmap'd by a C server as
easily as it is read by Python.  Everything is a (u32 offset table, byte blob)
pair so a reader needs no string parsing:

    off  size  field
    0    4     magic "QTK1"
    4    4     version = 1
    8    4     n_tokens
    12   4     n_merges
    16   4     eos_token_id
    20   4     padding_token_id
    24   4     bos_token_id       (0xFFFFFFFF when the GGUF carries none)
    28   4     add_bos            (0 or 1, as llama.cpp resolves it)
    32   4     flags              bit0 = clean_spaces
    36   4     reserved (0)
    40   64    pre-tokenizer name, NUL padded
    104  64    tokenizer model name, NUL padded
    168  8*8   section table: (offset u32, length u32) for 8 sections

    sections, in order:
      0 token offset table   u32 * (n_tokens + 1)
      1 token blob           UTF-8 bytes, in llama.cpp's GPT-2 byte-mapped form
      2 token_type           i32 * n_tokens
      3 merge offset table   u32 * (n_merges + 1)
      4 merge blob           "A B" strings, rank == index
      5 chat template        UTF-8 bytes
      6 reserved (empty)
      7 reserved (empty)

A sidecar JSON with only the small fields (ids, names, template) is written
alongside for humans; the vocab and merges live only in the .qtk.

Usage:
    extract_tokenizer.py MODEL.gguf OUT.qtk [--json OUT.json]
    extract_tokenizer.py --summary MODEL.gguf

The .qtk is ~7 MB for Qwen3.5-9B and is NOT committed; regenerate it with
this tool.  See docs/debugging/2026-08-28_qwen35-tokenizer.md.
"""

import argparse
import json
import os
import struct
import sys

# gguf-py from the local llama.cpp checkout -- same search order as pack_int4.py
for _p in ("/mnt/storage/llama-dflash2-src/gguf-py",
           os.path.expanduser("~/GitHub/llama.cpp.upstream/gguf-py")):
    if os.path.isdir(_p):
        sys.path.insert(0, _p)
        break
from gguf.gguf_reader import GGUFReader          # noqa: E402

MAGIC = b"QTK1"
VERSION = 1
HDR_BYTES = 168 + 8 * 8          # 232
NAME_BYTES = 64
N_SECTIONS = 8

# llama.cpp's llama_token_attr values, as stored in tokenizer.ggml.token_type
TOKEN_TYPE = {
    0: "UNDEFINED",
    1: "NORMAL",
    2: "UNKNOWN",
    3: "CONTROL",
    4: "USER_DEFINED",
    # llama.h:97-98 -- UNUSED IS 5 AND BYTE IS 6, not the other way round.
    # These two were swapped here, which is how the summary reported "243 BYTE
    # tokens" for a vocabulary that has ZERO of them.  The 243 are UNUSED
    # padding, [PAD248077]..[PAD248319].
    5: "UNUSED",
    6: "BYTE",
}


def _get(reader, key, default=None):
    f = reader.fields.get(key)
    if f is None:
        return default
    return f.contents()


def read_gguf_tokenizer(path):
    """Return every tokenizer field of a GGUF as plain Python objects."""
    r = GGUFReader(path, "r")

    tok_field = r.fields.get("tokenizer.ggml.tokens")
    if tok_field is None:
        raise SystemExit(f"{path}: no tokenizer.ggml.tokens -- not a tokenizer-bearing GGUF")

    n = len(tok_field.data)
    tokens = [tok_field.contents(i) for i in range(n)]

    tt_field = r.fields.get("tokenizer.ggml.token_type")
    if tt_field is None:
        token_type = [1] * n
    else:
        token_type = [int(tt_field.contents(i)) for i in range(len(tt_field.data))]

    mg_field = r.fields.get("tokenizer.ggml.merges")
    merges = ([mg_field.contents(i) for i in range(len(mg_field.data))]
              if mg_field is not None else [])

    out = {
        "model":          _get(r, "tokenizer.ggml.model", ""),
        "pre":            _get(r, "tokenizer.ggml.pre", ""),
        "architecture":   _get(r, "general.architecture", ""),
        "tokens":         tokens,
        "token_type":     token_type,
        "merges":         merges,
        "eos_token_id":   _get(r, "tokenizer.ggml.eos_token_id"),
        "bos_token_id":   _get(r, "tokenizer.ggml.bos_token_id"),
        "pad_token_id":   _get(r, "tokenizer.ggml.padding_token_id"),
        "unk_token_id":   _get(r, "tokenizer.ggml.unknown_token_id"),
        "add_bos_token":  _get(r, "tokenizer.ggml.add_bos_token"),
        "add_eos_token":  _get(r, "tokenizer.ggml.add_eos_token"),
        "chat_template":  _get(r, "tokenizer.chat_template", ""),
    }
    if len(out["token_type"]) != n:
        raise SystemExit(f"token_type has {len(out['token_type'])} entries, tokens has {n}")
    return out


def _resolve_add_bos(t):
    """Mirror llama.cpp's resolution, so the artefact records the same answer.

    src/llama-vocab.cpp: `bool add_bos = false;` at load, and the BPE branch of
    the vocab-type ladder does NOT set it (only SPM/WPM do).  It is then
    overridden only if LLM_KV_TOKENIZER_ADD_BOS is present.  This GGUF has no
    such key, so add_bos stays false and llama-tokenize prepends nothing.
    """
    if t["add_bos_token"] is not None:
        return 1 if t["add_bos_token"] else 0
    return 1 if t["model"] not in ("gpt2", "rwkv") and t["model"] in ("llama", "bert") else 0


def _clean_spaces(t):
    """qwen2/qwen35 pre-tokenizers set clean_spaces = false in llama.cpp."""
    return 0 if t["pre"] in ("qwen2", "qwen35", "deepseek-r1-qwen", "kormo",
                             "f2llmv2", "command-r", "poro-chat", "viking") else 1


def _pack_strings(strings):
    """(u32 offset table of len n+1, blob) for a list of str."""
    blob = bytearray()
    offs = [0]
    for s in strings:
        blob += s.encode("utf-8")
        offs.append(len(blob))
    return struct.pack(f"<{len(offs)}I", *offs), bytes(blob)


def write_qtk(t, path):
    tok_off, tok_blob = _pack_strings(t["tokens"])
    mrg_off, mrg_blob = _pack_strings(t["merges"])
    tt_bytes = struct.pack(f"<{len(t['token_type'])}i", *t["token_type"])
    tmpl = t["chat_template"].encode("utf-8")

    sections = [tok_off, tok_blob, tt_bytes, mrg_off, mrg_blob, tmpl, b"", b""]
    assert len(sections) == N_SECTIONS

    # section payloads start after the header, each 8-byte aligned
    table = []
    cur = HDR_BYTES
    body = bytearray()
    for sec in sections:
        pad = (-cur) % 8
        body += b"\0" * pad
        cur += pad
        table.append((cur, len(sec)))
        body += sec
        cur += len(sec)

    def name(s):
        b = s.encode("utf-8")[:NAME_BYTES]
        return b + b"\0" * (NAME_BYTES - len(b))

    bos = t["bos_token_id"]
    hdr = bytearray()
    hdr += MAGIC
    hdr += struct.pack("<IIIIII",
                       VERSION,
                       len(t["tokens"]),
                       len(t["merges"]),
                       int(t["eos_token_id"] if t["eos_token_id"] is not None else 0xFFFFFFFF),
                       int(t["pad_token_id"] if t["pad_token_id"] is not None else 0xFFFFFFFF),
                       int(bos if bos is not None else 0xFFFFFFFF))
    hdr += struct.pack("<III", _resolve_add_bos(t), _clean_spaces(t), 0)
    hdr += name(t["pre"])
    hdr += name(t["model"])
    for off, ln in table:
        hdr += struct.pack("<II", off, ln)
    assert len(hdr) == HDR_BYTES, len(hdr)

    with open(path, "wb") as f:
        f.write(hdr)
        f.write(body)
    return HDR_BYTES + len(body)


def read_qtk(path):
    """Inverse of write_qtk.  Used by tools/qwen35_tokenizer.py."""
    with open(path, "rb") as f:
        blob = f.read()
    if blob[:4] != MAGIC:
        raise ValueError(f"{path}: bad magic {blob[:4]!r}")
    (version, n_tok, n_mrg, eos, pad, bos) = struct.unpack_from("<IIIIII", blob, 4)
    (add_bos, clean_spaces, _rsv) = struct.unpack_from("<III", blob, 28)
    pre = blob[40:40 + NAME_BYTES].split(b"\0", 1)[0].decode()
    model = blob[104:104 + NAME_BYTES].split(b"\0", 1)[0].decode()
    table = [struct.unpack_from("<II", blob, 168 + 8 * i) for i in range(N_SECTIONS)]

    def sec(i):
        off, ln = table[i]
        return blob[off:off + ln]

    tok_off = struct.unpack(f"<{n_tok + 1}I", sec(0))
    tok_blob = sec(1)
    tokens = [tok_blob[tok_off[i]:tok_off[i + 1]].decode("utf-8")
              for i in range(n_tok)]
    token_type = list(struct.unpack(f"<{n_tok}i", sec(2)))
    mrg_off = struct.unpack(f"<{n_mrg + 1}I", sec(3))
    mrg_blob = sec(4)
    merges = [mrg_blob[mrg_off[i]:mrg_off[i + 1]].decode("utf-8")
              for i in range(n_mrg)]
    return {
        "version": version, "pre": pre, "model": model,
        "tokens": tokens, "token_type": token_type, "merges": merges,
        "eos_token_id": None if eos == 0xFFFFFFFF else eos,
        "pad_token_id": None if pad == 0xFFFFFFFF else pad,
        "bos_token_id": None if bos == 0xFFFFFFFF else bos,
        "add_bos": bool(add_bos), "clean_spaces": bool(clean_spaces),
        "chat_template": sec(5).decode("utf-8"),
    }


def summarise(t, out=sys.stdout):
    n = len(t["tokens"])
    counts = {}
    for tt in t["token_type"]:
        counts[tt] = counts.get(tt, 0) + 1
    print(f"architecture       : {t['architecture']}", file=out)
    print(f"tokenizer.model    : {t['model']}", file=out)
    print(f"tokenizer.pre      : {t['pre']}", file=out)
    print(f"n_tokens           : {n}", file=out)
    print(f"n_merges           : {len(t['merges'])}", file=out)
    for k in sorted(counts):
        print(f"  token_type {k} {TOKEN_TYPE.get(k, '?'):<13}: {counts[k]}", file=out)
    for k in ("bos_token_id", "eos_token_id", "pad_token_id", "unk_token_id",
              "add_bos_token", "add_eos_token"):
        v = t[k]
        extra = ""
        if isinstance(v, int) and k.endswith("_token_id") and 0 <= v < n:
            extra = f"  {t['tokens'][v]!r}"
        print(f"{k:<19}: {v}{extra}", file=out)
    print(f"add_bos (resolved) : {bool(_resolve_add_bos(t))}", file=out)
    print(f"clean_spaces       : {bool(_clean_spaces(t))}", file=out)
    print(f"chat_template chars: {len(t['chat_template'])}", file=out)
    specials = [(i, t["tokens"][i]) for i in range(n) if t["token_type"][i] in (2, 3, 4)]
    print(f"special tokens     : {len(specials)}", file=out)
    for i, s in specials[:64]:
        print(f"    {i:>7} {s!r}", file=out)
    if len(specials) > 64:
        print(f"    ... {len(specials) - 64} more", file=out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gguf")
    ap.add_argument("out", nargs="?", help="output .qtk path")
    ap.add_argument("--json", help="also write the small fields as JSON")
    ap.add_argument("--template", help="also write the raw chat template here")
    ap.add_argument("--summary", action="store_true", help="print a summary and exit")
    a = ap.parse_args()

    t = read_gguf_tokenizer(a.gguf)
    summarise(t)
    if a.summary:
        return
    if not a.out:
        ap.error("an output .qtk path is required unless --summary")

    n = write_qtk(t, a.out)
    print(f"\nwrote {a.out}  {n} bytes")

    if a.json:
        small = {k: t[k] for k in
                 ("model", "pre", "architecture", "eos_token_id", "bos_token_id",
                  "pad_token_id", "unk_token_id", "add_bos_token", "add_eos_token",
                  "chat_template")}
        small["n_tokens"] = len(t["tokens"])
        small["n_merges"] = len(t["merges"])
        small["add_bos_resolved"] = bool(_resolve_add_bos(t))
        small["clean_spaces"] = bool(_clean_spaces(t))
        small["special_tokens"] = {str(i): t["tokens"][i] for i in range(len(t["tokens"]))
                                   if t["token_type"][i] in (2, 3, 4)}
        with open(a.json, "w") as f:
            json.dump(small, f, indent=2, ensure_ascii=False)
        print(f"wrote {a.json}  {os.path.getsize(a.json)} bytes")

    if a.template:
        with open(a.template, "w") as f:
            f.write(t["chat_template"])
        print(f"wrote {a.template}  {os.path.getsize(a.template)} bytes")


if __name__ == "__main__":
    main()
