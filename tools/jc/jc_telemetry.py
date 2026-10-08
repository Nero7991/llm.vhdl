#!/usr/bin/env python3
"""Jungle Cat telemetry logger: periodic READ-ONLY sqrl_bridge scans.

Each cycle runs `sqrl_bridge C<bmc> skip skip` (no bitstream, VCCINT left
alone: the bridge rejects "skip" as voltage 0.00), reads the device scan and
the BMC's first Telemetry block, kills the bridge, and appends to a CSV:
  jtag rows: per die (mapped by DNA, never by device index; with die A off
             the chain, die B becomes Device 0), per-SLR temp and rails;
  bmc rows:  per BMC slot label, VCCINT VRM temp/voltage/current and the
             HBM VRM voltage/current.
An ALARM line goes to stdout and the CSV directory's alarms.log when a die
is missing or the BMC switched to slot B.

The CoE link has one owner at a time. Every cycle takes an exclusive flock
on --lock without waiting; a held lock (a load, the broker) skips the cycle.
Anything else that opens CoE must hold the same lock.

  jc_telemetry.py --bmc <ip> --bridge <path> --dies <jc_dies.json>
                  --out <dir> [--lock <file>] [--interval 60] [--once]
"""
import argparse
import datetime
import fcntl
import json
import os
import re
import select
import signal
import subprocess
import sys
import time

CSV_HEADER = ["ts", "src", "die", "nfpga", "slot_b_switch",
              "slr0_temp", "slr0_vccint", "slr0_vccaux", "slr0_vccbram",
              "slr1_temp", "slr1_vccint", "slr1_vccaux", "slr1_vccbram", "led",
              "t0", "v0", "t1", "v1", "vrm_temp", "vrm_v", "vrm_a", "hbm_v", "hbm_a"]

_FOUND = re.compile(r"^Found (\d+) FPGAs")
_DNA = re.compile(r"^Board \d+ Device (\d+) DNA: ([0-9a-fA-F]+)")
_TEMP = re.compile(r"^Board \d+ Device (\d+) SLR (\d) Temp: ([-\d.]+) C")
_RAIL = re.compile(r"^Board \d+ Device (\d+) SLR (\d) Rail (VCCINT|VCCAUX|VCCBRAM) Voltage: ([-\d.]+)")
_LED = re.compile(r"^Board \d+ Device (\d+) JungleCat .*LED RGBABCD: (.*)$")
_BMC = re.compile(r"^Board \d+ FPGA (\w+) TX .*\(([-\d.]+) C ([-\d.]+) V, ([-\d.]+) C ([-\d.]+) V, "
                  r"VRM ([-\d.]+) C, VRM ([-\d.]+) V, VRM ([-\d.]+) A, "
                  r"HBMVRM ([-\d.]+) V, HBMVRM ([-\d.]+) A\)")


def parse_scan(text, dies):
    """dies: {"A": dna_hex, "B": dna_hex}. Returns {nfpga, slot_b_switch, jtag, bmc}."""
    by_dna = {v.lower(): k for k, v in dies.items()}
    nfpga, switch = 0, False
    dev = {}   # device index -> fields
    bmc = {}
    for line in text.splitlines():
        line = line.strip()
        if "Switching to Slot B" in line:
            switch = True
        m = _FOUND.match(line)
        if m:
            nfpga = int(m.group(1))
            continue
        m = _DNA.match(line)
        if m:
            dev.setdefault(m.group(1), {})["dna"] = m.group(2).lower()
            continue
        m = _TEMP.match(line)
        if m:
            dev.setdefault(m.group(1), {})["slr%s_temp" % m.group(2)] = float(m.group(3))
            continue
        m = _RAIL.match(line)
        if m:
            dev.setdefault(m.group(1), {})["slr%s_%s" % (m.group(2), m.group(3).lower())] = float(m.group(4))
            continue
        m = _LED.match(line)
        if m:
            dev.setdefault(m.group(1), {})["led"] = m.group(2).strip()
            continue
        m = _BMC.match(line)
        if m and m.group(1) not in bmc:
            g = [float(x) for x in m.groups()[1:]]
            bmc[m.group(1)] = dict(zip(["t0", "v0", "t1", "v1", "vrm_temp", "vrm_v",
                                        "vrm_a", "hbm_v", "hbm_a"], g))
    jtag = {}
    for idx in sorted(dev, key=int):
        f = dict(dev[idx])
        dna = f.pop("dna", "")
        die = by_dna.get(dna, "dna_" + dna[-4:] if dna else "dev" + idx)
        jtag[die] = f
    return {"nfpga": nfpga, "slot_b_switch": switch, "jtag": jtag, "bmc": bmc}


def alarm(scan, expected=("A", "B")):
    missing = [d for d in expected if d not in scan["jtag"]]
    if scan["nfpga"] >= len(expected) and not scan["slot_b_switch"] and not missing:
        return None
    return "ALARM nfpga=%d slot_b_switch=%d missing=%s" % (
        scan["nfpga"], int(scan["slot_b_switch"]), ",".join(missing) or "-")


def csv_rows(ts, scan):
    rows = []
    for src in ("jtag", "bmc"):
        for die, f in scan[src].items():
            row = {"ts": ts, "src": src, "die": die, "nfpga": scan["nfpga"],
                   "slot_b_switch": int(scan["slot_b_switch"])}
            row.update(f)
            rows.append(["" if row.get(k) is None else str(row.get(k, "")) for k in CSV_HEADER])
    return rows


def run_bridge(bridge, bmc, timeout):
    """Run the bridge until every found FPGA has a Telemetry line, or timeout."""
    p = subprocess.Popen([bridge, "C" + bmc, "skip", "skip"], cwd=os.path.dirname(bridge),
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         start_new_session=True)
    fd, buf, deadline = p.stdout.fileno(), b"", time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            r, _, _ = select.select([fd], [], [], 0.5)
            if not r:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            buf += chunk
            s = parse_scan(buf.decode("utf-8", "replace"), {})
            if s["nfpga"] and len(s["bmc"]) >= s["nfpga"]:
                break
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
        p.stdout.close()
    return buf.decode("utf-8", "replace")


def cycle(a, dies):
    ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    with open(a.lock, "a") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("SKIP %s lock held" % ts, flush=True)
            return
        text = run_bridge(a.bridge, a.bmc, a.timeout)
    with open(os.path.join(a.out, "raw-%s.log" % ts[:10]), "a") as f:
        f.write("=== %s\n%s\n" % (ts, text))
    scan = parse_scan(text, dies)
    path = os.path.join(a.out, "telemetry.csv")
    new = not os.path.exists(path)
    with open(path, "a") as f:
        if new:
            f.write(",".join(CSV_HEADER) + "\n")
        for r in csv_rows(ts, scan):
            f.write(",".join(r) + "\n")
    al = alarm(scan)
    if al:
        with open(os.path.join(a.out, "alarms.log"), "a") as f:
            f.write("%s %s\n" % (ts, al))
        print("%s %s" % (ts, al), flush=True)
    else:
        print("OK %s %s" % (ts, " ".join("%s:%.1fC/%.2fA" % (d, b["t0"], b["vrm_a"])
                                        for d, b in scan["bmc"].items())), flush=True)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--bmc", required=True)
    ap.add_argument("--bridge", required=True)
    ap.add_argument("--dies", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--lock", default=os.path.expanduser("~/jc_coe.lock"))
    ap.add_argument("--interval", type=float, default=60)
    ap.add_argument("--timeout", type=float, default=45)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    with open(a.dies) as f:
        dies = json.load(f)
    while True:
        t0 = time.monotonic()
        cycle(a, dies)
        if a.once:
            return 0
        time.sleep(max(0.0, a.interval - (time.monotonic() - t0)))


if __name__ == "__main__":
    sys.exit(main())
