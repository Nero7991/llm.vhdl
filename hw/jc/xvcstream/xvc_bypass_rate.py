#!/usr/bin/env python3
"""Measure raw XVC shift throughput over the SQRL CoE bridge, with integrity check.

Puts every device on the chain in BYPASS (IR all ones, non-destructive), then
streams DR shifts of a given size. In BYPASS each device is a 1-bit register, so
TDO is TDI delayed by N bits (N = devices on the chain). The delay is found once,
then every later shift is checked against it.

Usage: xvc_bypass_rate.py <host:port> <bits_per_shift> <total_MB> [timeout_s]
Prints XVCRATE ... lines; exits nonzero on mismatch or hang (socket timeout).
"""
import socket, struct, sys, time, os

def recv_exact(s, n):
    b = bytearray()
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise ConnectionError("XVC closed")
        b += c
    return bytes(b)

def shift(s, nbits, tms, tdi):
    nb = (nbits + 7) // 8
    s.sendall(b"shift:" + struct.pack("<I", nbits) + tms + tdi)
    return recv_exact(s, nb)

def bits_to_bytes(bits):
    out = bytearray((len(bits) + 7) // 8)
    for i, v in enumerate(bits):
        if v: out[i >> 3] |= 1 << (i & 7)
    return bytes(out)

def tms_seq(s, seq):
    shift(s, len(seq), bits_to_bytes(seq), bits_to_bytes([0] * len(seq)))

def get_bit(buf, i): return (buf[i >> 3] >> (i & 7)) & 1

def main():
    hp, nbits, total_mb = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
    to = float(sys.argv[4]) if len(sys.argv) > 4 else 10.0
    host, port = hp.split(":")
    s = socket.create_connection((host, int(port)), timeout=to)
    s.sendall(b"getinfo:"); info = s.recv(64)
    print("XVCINFO", info.strip().decode(errors="replace"), flush=True)
    # Test-Logic-Reset, then Run-Test/Idle
    tms_seq(s, [1, 1, 1, 1, 1, 0])
    # RTI -> Select-DR -> Select-IR -> Capture-IR -> Shift-IR
    tms_seq(s, [1, 1, 0, 0])
    # 64 ones into IR (more than the whole chain's IR length), last bit exits
    n = 64
    tms = [0] * (n - 1) + [1]
    shift(s, n, bits_to_bytes(tms), bits_to_bytes([1] * n))
    # Exit1-IR -> Update-IR -> RTI ; RTI -> Select-DR -> Capture-DR -> Shift-DR
    tms_seq(s, [1, 0])
    tms_seq(s, [1, 0, 0])
    # find the bypass delay: shift a single 1 followed by zeros
    probe = [1] + [0] * 63
    tdo = shift(s, 64, bits_to_bytes([0] * 64), bits_to_bytes(probe))
    ones = [i for i in range(64) if get_bit(tdo, i)]
    print("XVCDELAY ones_at", ones, flush=True)
    if len(ones) != 1:
        print("XVCRATE_FAIL cannot find a single bypass delay"); sys.exit(2)
    d = ones[0]
    # stream: stay in Shift-DR (TMS all 0). Check TDO[i] == TDI[i-d] across shifts.
    nbytes = nbits // 8
    tms0 = bytes(nbytes)
    rnd = os.urandom
    total = int(total_mb * 1e6)
    sent = 0; nshift = 0; prev_tail = None; bad = 0
    t0 = time.perf_counter(); worst = 0.0
    while sent < total:
        tdi = rnd(nbytes)
        ts = time.perf_counter()
        tdo = shift(s, nbits, tms0, tdi)
        dt = time.perf_counter() - ts; worst = max(worst, dt)
        # integrity: bit i of tdo equals bit i-d of the concatenated tdi stream
        if prev_tail is not None:
            for i in range(0, nbits, 997):          # sampled check, every ~1000th bit
                j = i - d
                exp = get_bit(tdi, j) if j >= 0 else get_bit(prev_tail, nbits + j)
                if get_bit(tdo, i) != exp: bad += 1
        prev_tail = tdi
        sent += nbytes; nshift += 1
    el = time.perf_counter() - t0
    rate = sent / el
    print("XVCRATE bits/shift=%d shifts=%d bytes=%d %.2fs  %.1f KB/s  mean %.2f ms/shift  worst %.2f ms  bad_samples=%d  -> 7GB in %.1f h"
          % (nbits, nshift, sent, el, rate / 1024, el / nshift * 1e3, worst * 1e3, bad, 7e9 / rate / 3600), flush=True)
    # leave the TAP in RTI
    tms_seq(s, [1, 1, 0])
    s.close()
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
