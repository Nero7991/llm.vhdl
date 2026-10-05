"""Independent Python model of the Jungle Cat loader (spec S4, plan rulings).

The oracle for every loader bench and for the host tests. It shares the format
definitions in jc_frame.py and nothing with the RTL.
"""
import zlib
from . import jc_frame as F

class LoaderModel:
    def __init__(self, bad_bresp_addrs=()):
        self.mem = {}
        self.bad_bresp_addrs = set(bad_bresp_addrs)
        self.last = 0xFFFFFFFF
        self.committed = self.crc_fail = self.seq_err = self.desync = 0
        self.bresp_err = self.dup = 0
        self.range_valid = self.range_crc = self.range_seq = 0

    def feed(self, slot):
        h = F.parse_header(slot)
        if h["magic"] != F.MAGIC_FRAME or h["nwords"] > F.MAX_PAYLOAD_WORDS:
            self.desync += 1
            return
        if not F.slot_crc_ok(slot):
            self.crc_fail += 1
            return
        if h["nwords"] == 0 and h["flags"] & F.FLAG_RANGE_CRC == 0:
            return                                            # status poll
        expect = (self.last + 1) & 0xFFFFFFFF
        diff = (h["seq"] - expect) & 0xFFFFFFFF
        if diff != 0:
            if diff >= 0x80000000:
                self.dup += 1
            else:
                self.seq_err += 1
            return
        if h["flags"] & F.FLAG_RANGE_CRC:
            data = b"".join(self.mem.get(a, bytes(32))
                            for a in range(h["addr"], h["addr"] + h["range_len"], 32))
            self.range_crc = zlib.crc32(data) & 0xFFFFFFFF
            self.range_seq = h["seq"]
            self.range_valid = 1
        else:
            for a, n in F.bursts(h["addr"], h["nwords"]):
                if a in self.bad_bresp_addrs:
                    self.bresp_err += 1
            for k in range(h["nwords"]):
                self.mem[h["addr"] + 32 * k] = slot[32 * (k + 1):32 * (k + 2)]
        self.last = h["seq"]
        self.committed += 1

    def status(self):
        return dict(magic=F.MAGIC_STAT, last=self.last, committed=self.committed,
                    crc_fail=self.crc_fail, seq_err=self.seq_err, desync=self.desync,
                    bresp_err=self.bresp_err, dup=self.dup, busy=0, hbm_trip=0,
                    range_valid=self.range_valid, fifo_ovf=0, range_rerr=0,
                    range_crc=self.range_crc, range_seq=self.range_seq)

class FifoOverflowModel:
    """Fix round 1 (I1): an explicit model of jc_frame_core -> async_fifo(DEPTH) ->
    jc_hbm_writer at FIFO-ENTRY granularity (header / data / verdict), used only to derive
    the expected outcome of sim/tb_jc_loader_ovf.vhd, where the caller deliberately gates the
    AXI3 AW channel closed over a span of frames and the FIFO must actually overflow.

    LoaderModel above assumes every transmitted frame reaches the writer whole; that is true
    for every OTHER bench (their only backpressure is jc_axi3_mem's random STALL, which never
    drops a beat because the real async_fifo and jc_hbm_writer both hold their request lines
    until the far side is ready). It is not true here: jc_frame_core pushes one FIFO entry per
    completed word UNCONDITIONALLY, with no regard to the FIFO's own w_ready, and relies
    entirely on async_fifo's write-side backpressure (rtl/async_fifo.vhd's `wr_now`) to decide
    whether that push actually lands; a push issued while the FIFO is full is simply lost,
    which is the real hardware's overflow condition (and what sets status bit 179).

    This model reproduces exactly that: a bounded FIFO queue a caller-chosen producer feeds
    one entry at a time (push silently dropped, `ovf` latched, once the queue is at `depth`),
    drained by a writer state machine that mirrors jc_hbm_writer's S_HDR / S_COLLECT /
    S_DECIDE exactly, including the "lost verdict" branch (a second header arriving in
    S_COLLECT with no intervening verdict: ruling 6, counted as a CRC failure) and a `BLOCKED`
    state standing in for jc_hbm_writer's S_AW/S_W/S_B once it has decided a frame must be
    written and the caller's AW gate is shut -- in that state the writer drains nothing
    further from the queue, exactly like the real writer's q_ready, which is only '1' in
    S_HDR/S_COLLECT.

    The caller drives `set_gate(False/True)` at frame boundaries to model the testbench's AW
    gate, and `feed_slot` to decompose one 2048-byte slot into frame_core's pushes (nothing
    pushed for a bad-magic slot, matching frame_core's desync handling). This was validated
    against an actual GHDL run of rtl/jc_loader_core.vhd with the matching gate schedule
    during Task 6 fix round 1 (see docs/claude or task-6-report.md): both agreed on every
    field, and a temporary `report` added inside jc_hbm_writer.vhd's TAG_HDR-in-S_COLLECT
    branch confirmed the lost-verdict path fires exactly once, matching this model's
    crc_fail=1.

    FIFO CAPACITY, CORRECTED (fix round 2, I2): the real push-side capacity is `depth + 2`,
    not `depth`. rtl/async_fifo.vhd's read side has a 2-entry output stage (`ob`) that
    prefetches from the main `mem` array independently of whether the external consumer
    (q_ready) is ready, as long as `ob` has room and `mem` has unread entries. Every beat
    `ob` prefetches advances `rp`, which is what the WRITE side's `used_w = wp - rp_bin_w`
    is computed from -- so from the write side's point of view, up to 2 beats that the
    writer has not actually consumed yet (they are sitting in `ob`, not yet handed across
    q_valid/q_ready) already look "free". A caller-chosen `OUT_STAGE` (default 2) models
    this; the fix round 1 report, before this was known, assumed exactly `depth` and so
    said seq4's frame in sim/tb_jc_loader_ovf.vhd would have only its header survive (1
    accepted, 63 dropped); MEASURED (a temporary per-slot accept/drop probe in a scratch
    jc_frame_core.vhd) it actually accepts 3 (header + 2 data words) and drops 61. The
    scenario's final status/memory (T line) is unchanged either way -- see
    tools/jc/gen_jc_vectors.py's gen_loader_ovf docstring for why, and the measured range
    of capacities over which that holds.
    """
    def __init__(self, depth=128, out_stage=2):
        self.depth = depth
        self.out_stage = out_stage   # async_fifo's `ob`: see this class's docstring
        self.queue = []           # pending FIFO entries, in order: ("H", hdr_dict) /
                                   # ("D", 32 bytes) / ("V", crc_ok_bool, seq)
        self.state = "HDR"        # writer state: HDR, COLLECT, BLOCKED
        self.h = None
        self.cnt = 0
        self.buf = []
        self.pending = None       # (header, buf) waiting on the AW gate while BLOCKED
        self.last = 0xFFFFFFFF
        self.mem = {}
        self.committed = self.crc_fail = self.seq_err = self.dup = self.desync = 0
        self.ovf = False
        self.gate_open = True

    def set_gate(self, open_):
        self.gate_open = open_
        self._drain()

    def feed_slot(self, slot):
        h = F.parse_header(slot)
        if h["magic"] != F.MAGIC_FRAME or h["nwords"] > F.MAX_PAYLOAD_WORDS:
            self.desync += 1
            return                                             # frame_core pushes nothing
        self._push(("H", h))
        for k in range(h["nwords"]):
            self._push(("D", slot[32 * (k + 1):32 * (k + 2)]))
        self._push(("V", F.slot_crc_ok(slot), h["seq"]))

    def _push(self, item):
        if len(self.queue) < self.depth + self.out_stage:
            self.queue.append(item)
        else:
            self.ovf = True                                    # dropped: FIFO was full
        self._drain()

    def _drain(self):
        while True:
            if self.state == "BLOCKED":
                if not self.gate_open:
                    return
                h, buf = self.pending
                for k, w in enumerate(buf):
                    self.mem[h["addr"] + 32 * k] = w
                self.last = h["seq"]; self.committed += 1
                self.pending = None; self.state = "HDR"
            if not self.queue:
                return
            if self.state == "HDR":
                _, h = self.queue.pop(0)                         # always a header here
                self.h = h; self.cnt = 0; self.buf = []
                self.state = "COLLECT"
            else:                                                # COLLECT
                item = self.queue.pop(0)
                if item[0] == "D":
                    if self.cnt < F.MAX_PAYLOAD_WORDS:
                        self.buf.append(item[1])
                    self.cnt += 1
                elif item[0] == "H":
                    self.crc_fail += 1                            # lost verdict (ruling 6)
                    self.h = item[1]; self.cnt = 0; self.buf = []
                else:
                    ok = item[1] and self.cnt == self.h["nwords"]
                    if not ok:
                        self.crc_fail += 1; self.state = "HDR"
                    elif self.h["nwords"] == 0 and self.h["flags"] == 0:
                        self.state = "HDR"                        # status poll
                    else:
                        expect = (self.last + 1) & 0xFFFFFFFF
                        diff = (self.h["seq"] - expect) & 0xFFFFFFFF
                        if diff == 0:
                            if self.h["flags"] & F.FLAG_RANGE_CRC:
                                self.last = self.h["seq"]; self.committed += 1
                                self.state = "HDR"                 # not AW-gated
                            elif self.gate_open:
                                for k, w in enumerate(self.buf):
                                    self.mem[self.h["addr"] + 32 * k] = w
                                self.last = self.h["seq"]; self.committed += 1
                                self.state = "HDR"
                            else:
                                self.pending = (self.h, self.buf)
                                self.state = "BLOCKED"
                        elif diff >= 0x80000000:
                            self.dup += 1; self.state = "HDR"
                        else:
                            self.seq_err += 1; self.state = "HDR"

    def status(self):
        return dict(last=self.last, committed=self.committed, crc_fail=self.crc_fail,
                    seq_err=self.seq_err, dup=self.dup, desync=self.desync, ovf=int(self.ovf))
