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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tools"))
from jc.coe import CoE, tms_payload, pair_payload

def ir_all_ones_payload(n):
    return pair_payload([1] * n, [0] * (n - 1) + [1])

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
