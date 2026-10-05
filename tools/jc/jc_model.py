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
