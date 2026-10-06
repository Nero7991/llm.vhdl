"""Spot-check windows chosen from a weight manifest (plan Task 11, step 6).

  spot_check_manifest.py gen <manifest> <n> <seed> <addrs_out> <expect_out>
      picks n random pieces (weighted by size), a random 32-byte aligned 256-byte window
      inside each, writes one hex HBM address per line for spot_check.tcl and the expected
      bytes (hex) for each window from the source files.
  spot_check_manifest.py cmp <expect_out> <spot_out>
      compares spot_check.tcl's SPOT lines with the expected bytes. Vivado prints a
      multi-beat hw_axi DATA highest address first; every window must match in that order.
"""
import json, os, random, sys

WIN = 256

def pieces(manifest):
    m = json.load(open(manifest))
    base = os.path.dirname(os.path.abspath(manifest))
    out = []
    for f in m["files"]:
        path = os.path.join(base, f["file"])
        ps = f.get("pieces") or [dict(file_offset=0, nbytes=f["nbytes"], hbm_offset=f["hbm_offset"])]
        for p in ps:
            if p["nbytes"] >= WIN:
                out.append((path, p["file_offset"], p["nbytes"], p["hbm_offset"]))
    return out

def gen(manifest, n, seed, addrs_out, expect_out):
    rng = random.Random(seed)
    ps = pieces(manifest)
    weights = [p[2] for p in ps]
    seen = set()
    with open(addrs_out, "w") as fa, open(expect_out, "w") as fe:
        while len(seen) < n:                      # n DISTINCT windows
            path, foff, nb, hoff = rng.choices(ps, weights=weights, k=1)[0]
            off = rng.randrange(0, (nb - WIN) // 32 + 1) * 32
            if hoff + off in seen:
                continue
            seen.add(hoff + off)
            with open(path, "rb") as fh:
                fh.seek(foff + off)
                data = fh.read(WIN)
            fa.write("%x\n" % (hoff + off))
            fe.write("%x %s\n" % (hoff + off, data.hex()))

def cmp(expect_out, spot_out):
    want = {}
    for line in open(expect_out):
        a, h = line.split()
        want[int(a, 16)] = bytes.fromhex(h)
    n = ok = 0
    bad = []
    for line in open(spot_out):
        if not line.startswith("SPOT "):
            continue
        _, a, h = line.split()
        a = int(a, 16); n += 1
        if bytes.fromhex(h)[::-1] == want.get(a):
            ok += 1
        else:
            bad.append(hex(a))
    print("SPOT_COMPARE windows=%d expected=%d match=%d bad=%s" % (n, len(want), ok, bad[:10]))
    return 0 if n and n == len(want) and ok == n else 1

if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6])
    else:
        sys.exit(cmp(sys.argv[2], sys.argv[3]))
