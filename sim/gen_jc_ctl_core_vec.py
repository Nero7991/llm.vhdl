#!/usr/bin/env python3
"""Write sim/jc_ctl_core_vec.txt for sim/tb_jc_ctl_core.vhd (plan Task 4).

The slots come from the HOST library, tools/jc/jc_ctl.py build_slot (realigned to the
final protocol at 1da3e2e: ack fields, rsp_crc, st_crc). The bench builds every frame it
sends with its own builder and its own bytewise CRC-32; for each slot in this file it
first rebuilds the same frame and requires bit-for-bit equality. So the host library, the
bench's builder and (through the end-to-end checks) the RTL must all agree.

Items: item(salt, i) = lo32(p) ^ hi32(p) ^ 0x3C000000 with p = ((salt << 16) + i + 1) *
0x9E3779B9; the bench has the same function.

Format: '#' comment lines, then one line per slot:
  V <name> <seq> <op> <addr, 16 hex digits> <count> <ack_seq> <ack_valid> <salt> <slot>
<slot> is jc_ctl.slot_hex(slot): 4096 hex digits of the slot as ONE little-endian
integer, most significant digit first, so TDI bit i is bit i of that integer.

Usage: python3 sim/gen_jc_ctl_core_vec.py [out_path]   (default: sim/jc_ctl_core_vec.txt)
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools", "jc"))
import jc_ctl  # noqa: E402


def item(salt, i):
    p = ((salt << 16) + i + 1) * 0x9E3779B9
    return (p & 0xFFFFFFFF) ^ ((p >> 32) & 0xFFFFFFFF) ^ 0x3C000000


# (name, seq, op, addr, count, ack_seq, ack_valid, salt)  salt 0 = no payload
CASES = [
    ("wr496",  1, jc_ctl.OP_WR_INC, 0x1000, 496, 0, 0, 1),
    ("rd496",  2, jc_ctl.OP_RD_INC, 0x1000, 496, 0, 0, 0),
    ("nopack", 3, jc_ctl.OP_NOP, 0, 1, 2, 1, 0),
    ("wrack",  7, jc_ctl.OP_WR_FIX, 0x3000, 9, 0x00012345, 1, 2),
    ("memrd",  0x30, jc_ctl.OP_MEM_RD, 0x100000000, 496, 0x2F, 1, 0),
]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "jc_ctl_core_vec.txt")
    lines = ["# jc_ctl_core_vec.txt: host-library slots for sim/tb_jc_ctl_core.vhd.",
             "# Written by sim/gen_jc_ctl_core_vec.py from tools/jc/jc_ctl.py build_slot.",
             "# V <name> <seq> <op> <addr, 16 hex digits> <count> <ack_seq> <ack_valid> <salt> <slot hex>"]
    for name, seq, op, addr, count, ack_seq, ack_valid, salt in CASES:
        items = [item(salt, i) for i in range(count)] if op in jc_ctl.WRITE_OPS else None
        slot = jc_ctl.build_slot(seq, op, addr, items, count, ack_seq=ack_seq,
                                 ack_valid=ack_valid)
        assert len(slot) == jc_ctl.SLOT_BYTES and jc_ctl.slot_crc_ok(slot)
        lines.append("V %s %d %d %016x %d %d %d %d %s" % (name, seq, op, addr, count, ack_seq,
                                                      ack_valid, salt, jc_ctl.slot_hex(slot)))
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
