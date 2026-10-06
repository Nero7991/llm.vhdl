"""Compare spot_check.tcl's SPOT lines against the source file (plan Task 11).

Usage: spot_check_compare.py <spot_out> <file> <hbm_base_hex>
Vivado prints a multi-word hw_axi DATA with the highest-addressed 32-bit word first; the
first window decides between that order and the reverse, and every window must then match
in that same order (a random 256-byte window cannot match by chance).
"""
import sys

def words_le(b):
    return [b[i:i + 4] for i in range(0, len(b), 4)]

def main():
    spot, path, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
    data = open(path, "rb").read()
    order, ok, bad, n = None, 0, [], 0
    for line in open(spot):
        if not line.startswith("SPOT "):
            continue
        _, a, hexdata = line.split()
        a = int(a, 16); n += 1
        want = data[a - base:a - base + len(hexdata) // 2]
        got = bytes.fromhex(hexdata)
        cand = {"hi_first": got[::-1],
                "lo_first": b"".join(w[::-1] for w in words_le(got))}
        if order is None:
            for k, v in cand.items():
                if v == want:
                    order = k
        if order is not None and cand[order] == want:
            ok += 1
        else:
            bad.append(hex(a))
    print("SPOT_COMPARE windows=%d match=%d order=%s bad=%s" % (n, ok, order, bad[:10]))
    sys.exit(0 if n and ok == n else 1)

if __name__ == "__main__":
    main()
