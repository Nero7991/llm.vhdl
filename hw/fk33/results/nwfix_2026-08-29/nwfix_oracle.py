#!/usr/bin/env python3
"""nwfix_oracle.py -- TRACK NWFIX, 2026-08-29.  SCRATCH, not in tools/.

The INDEPENDENT side of the values oracle.  Reads the same NORM_W_IMAGE with
its own reader and prints the same three numbers per norm op that
`nwfix_oracle.vhd` prints from the elaborated `NW_TBL`, in the same format, so
the two can be compared with `diff`.

This is deliberately NOT the writer.  `sim/ooc_nwrom_gen_image.py` produced the
file from the gguf; this reads it back with four lines of parsing that share no
code with it.  Comparing a writer against its own reader is a round trip and
proves nothing (the `m7 mutant` case).

NO HARDWARE.
"""
import sys

def main() -> int:
    path, nn = sys.argv[1], int(sys.argv[2])
    vals = []
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if not s:
                continue
            u = int(s, 16)
            vals.append(u - 65536 if u >= 32768 else u)
    if len(vals) % nn != 0:
        print(f"NWFIX_ORACLE_PY_SHORT lines={len(vals)} nn={nn}")
        return 2
    n = len(vals) // nn
    print(f"NWFIX_ORACLE_NW_N {n}")
    for k in range(n):
        seg = vals[k * nn:(k + 1) * nn]
        w = sum(((i + 1) % 4096) * v for i, v in enumerate(seg)) % 16777216
        print(f"NWFIX_ORACLE_OP {k} sum24={sum(seg) % 16777216}"
              f" wsum24={w} first={seg[0]} last={seg[-1]}")
    print("NWFIX_ORACLE_DONE")
    return 0

if __name__ == "__main__":
    sys.exit(main())
