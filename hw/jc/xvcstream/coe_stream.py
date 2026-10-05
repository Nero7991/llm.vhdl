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
from jc.coe import CoE, tms_payload, pair_payload, CoEError

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
    # Every TMS move now goes through a vetted CoE method (fix round 3): resync() in
    # place of a raw reset, ir_shift_all_ones() for the IR shift (both already true as
    # of fix rounds 1-2), and now to_shift_dr()/exit_dr_to_idle() in place of the old
    # raw toDR/exit CMD_TMS calls through call() -- call() only accepts the handshake
    # commands now, and there is no public way to send a CMD_TMS payload at all.
    c.resync()
    c.ir_shift_all_ones(64)
    c.to_shift_dr()
    def dr(nb, tdi):
        # CMD_TDI is pipelined, not request/reply like the handshake commands, so it
        # goes through the public send()/reply() pair rather than call() (fix round 3
        # item A: send() accepts only CMD_TDI, reply() now takes the expected txn).
        t = c.send(0x8000100f, struct.pack("<BBH", 0, 0x20, nb) + tdi)
        return c.reply(t)[1]
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
        # fix round 3 item C: reply() now takes the expected txn and checks it AND the
        # status itself, raising CoEError (no silent return) on either mismatch --
        # fix round 2 item 8's separate status check folds into that. Receive-side
        # only; this changes nothing about what is sent.
        try:
            st, tdo = c.reply(t)
        except CoEError as e:
            print("COE_FAIL", e); sys.exit(3)
        if len(tdo) != nbytes:
            print("COE_FAIL len", len(tdo)); sys.exit(3)
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
    c.exit_dr_to_idle()
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
