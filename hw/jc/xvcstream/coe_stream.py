#!/usr/bin/env python3
"""Direct SQRL CoE client (no sqrl_bridge): pipelined BYPASS loopback throughput.

Protocol RE'd from captures 2026-10-05 (docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md S12).
Request:  u16 len(total, LE) | u16 txn | u32 cmd (LE) | payload
Reply:    u16 len | u16 txn | u32 0x8000000a | data
Only commands observed from the stock bridge are sent:
  0x80001000 hello, 0x8000100c speed, 0x80001001 mode, 0x80001010 idcodes,
  0x80001011 IR lengths, 0x8000100e TMS+TDI shift, 0x8000100f TDI-only shift.
Usage: coe_stream.py <bmc_ip> <tck_hz> <bits_per_shift> <total_MB> <depth>
"""
import socket, struct, sys, time, os

class CoE:
    def __init__(s, ip, port=21363, to=10.0):
        s.s = socket.create_connection((ip, port), timeout=to)
        s.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.txn = 1
    def send(s, cmd, payload=b""):
        # txn bit 15 is not a counter bit: txn 0x8000 drew a 4-byte error reply (MEASURED)
        t = s.txn; s.txn = s.txn + 1 if s.txn < 0x7fff else 1
        s.s.sendall(struct.pack("<HHI", 8 + len(payload), t, cmd) + payload)
        return t
    def recv_exact(s, n):
        b = bytearray()
        while len(b) < n:
            c = s.s.recv(n - len(b))
            if not c: raise ConnectionError("CoE closed")
            b += c
        return bytes(b)
    def reply(s):
        h = s.recv_exact(8)
        L, t, st = struct.unpack("<HHI", h)
        return t, st, s.recv_exact(L - 8)
    def call(s, cmd, payload=b""):
        t = s.send(cmd, payload)
        while True:
            rt, st, d = s.reply()
            if rt == t: return st, d

def tms_payload(tms_bits):
    # cmd 0x8000100e: dev 0, flags 0, count, then (TDI byte, TMS byte) pairs; TDI 0 here
    n = len(tms_bits); out = bytearray(struct.pack("<BBH", 0, 0, n))
    for k in range(0, n, 8):
        out += bytes([0, sum(tms_bits[k + j] << j for j in range(min(8, n - k)))])
    return bytes(out)

def ir_all_ones_payload(n):
    # cmd 0x8000100e long form: dev 0, flags 0, count, then (TDI byte, TMS byte) pairs
    tdi = [1] * n; tms = [0] * (n - 1) + [1]
    out = bytearray(struct.pack("<BBH", 0, 0, n))
    for k in range(0, n, 8):
        bt = sum(tdi[k + j] << j for j in range(min(8, n - k)))
        bm = sum(tms[k + j] << j for j in range(min(8, n - k)))
        out += bytes([bt, bm])
    return bytes(out)

def main():
    ip, hz, nbits, total_mb, depth = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
    c = CoE(ip)
    print("HELLO", c.call(0x80001000)[0] == 0x8000000a, flush=True)
    st, _ = c.call(0x8000100c, struct.pack("<II", 0, hz)); print("SPEED", hz, hex(st), flush=True)
    c.call(0x80001001, bytes.fromhex("0002"))
    st, d = c.call(0x80001010, bytes.fromhex("0000")); print("IDCODES", d.hex(), flush=True)
    if d != bytes.fromhex("9310b7149310b714"):
        print("COE_FAIL unexpected IDCODEs"); sys.exit(2)
    c.call(0x80001011, bytes.fromhex("000c0c"))
    c.call(0x80001001, bytes.fromhex("0001"))
    # TAP: reset -> RTI -> Shift-IR, 64 ones (BYPASS everywhere), Update-IR -> RTI -> Shift-DR
    c.call(0x8000100e, tms_payload([1, 1, 1, 1, 1, 0]))
    c.call(0x8000100e, tms_payload([1, 1, 0, 0]))
    c.call(0x8000100e, ir_all_ones_payload(64))
    c.call(0x8000100e, tms_payload([1, 0]))
    c.call(0x8000100e, tms_payload([1, 0, 0]))
    def dr(nb, tdi):
        return c.call(0x8000100f, struct.pack("<BBH", 0, 0x20, nb) + tdi)[1]
    tdo = dr(64, bytes([1]) + bytes(7))
    ones = [i for i in range(64) if (tdo[i >> 3] >> (i & 7)) & 1]
    print("DELAY", ones, flush=True)
    if len(ones) != 1: print("COE_FAIL no single bypass delay"); sys.exit(2)
    d0 = ones[0]
    nbytes = nbits // 8; mask = (1 << nbits) - 1
    nsend = int(total_mb * 1e6) // nbytes
    hdr = struct.pack("<BBH", 0, 0x20, nbits)
    q = []; issued = done = bad = 0; prev = None; worst = 0.0
    t0 = time.perf_counter()
    while done < nsend:
        while issued < nsend and len(q) < depth:
            tdi = os.urandom(nbytes); q.append((c.send(0x8000100f, hdr + tdi), tdi, time.perf_counter())); issued += 1
        t, tdi, ts = q.pop(0)
        rt, st, tdo = c.reply()
        if rt != t or len(tdo) != nbytes: print("COE_FAIL txn/len", rt, t, len(tdo), hex(st), tdo.hex()); sys.exit(3)
        worst = max(worst, time.perf_counter() - ts)
        ti = int.from_bytes(tdi, "little"); to_ = int.from_bytes(tdo, "little")
        if prev is None:
            exp = (ti << d0) & mask; to_ &= mask & ~((1 << d0) - 1)
        else:
            exp = ((ti << d0) | (prev >> (nbits - d0))) & mask
        bad += bin(exp ^ to_).count("1"); prev = ti; done += 1
    el = time.perf_counter() - t0; rate = done * nbytes / el
    print("COERATE tck=%d depth=%d bits/shift=%d shifts=%d %.2fs %.1f KB/s mean %.3f ms/shift worst %.2f ms bad_bits=%d -> 7GB in %.2f h"
          % (hz, depth, nbits, done, el, rate / 1024, el / done * 1e3, worst * 1e3, bad, 7e9 / rate / 3600), flush=True)
    c.call(0x8000100e, tms_payload([1, 1, 0]))
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
