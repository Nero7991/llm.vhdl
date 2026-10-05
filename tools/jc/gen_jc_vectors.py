#!/usr/bin/env python3
"""Write the Jungle Cat loader bench vectors (sim/jc_*_vec.txt).

Every expected value comes from zlib and tools/jc/jc_model.py, never from the RTL.
Usage: gen_jc_vectors.py [--only crc32|frame|writer|crcunit|loader]
"""
import argparse, os, random, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

def sim(name):
    return os.path.join(REPO, "sim", name)

def gen_crc32(rng):
    lines = []
    for n in (1, 2, 8, 63, 504):
        words = [rng.getrandbits(32) for _ in range(n)]
        data = b"".join(struct.pack("<I", w) for w in words)
        crc = zlib.crc32(data) & 0xFFFFFFFF
        lines.append("%d %s %08x" % (n, " ".join("%08x" % w for w in words), crc))
    # zlib's published check value: CRC-32("123456789") = 0xcbf43926, 9 bytes padded is
    # not word-aligned, so use the 8-byte prefix "12345678" instead.
    data = b"12345678"
    w = struct.unpack("<2I", data)
    lines.append("2 %08x %08x %08x" % (w[0], w[1], zlib.crc32(data) & 0xFFFFFFFF))
    with open(sim("jc_crc32_vec.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

def gen_frame(rng):
    from jc import jc_frame as F
    slots = []          # (slot, magic_ok, nwords, pass, seq)
    def add(s, ok=True):
        h = F.parse_header(s)
        good = ok and h["magic"] == F.MAGIC_FRAME and h["nwords"] <= F.MAX_PAYLOAD_WORDS
        slots.append((s, int(good), h["nwords"] if good else 0,
                      int(good and F.slot_crc_ok(s)), h["seq"] if good else 0))
    add(bytes(F.SLOT_BYTES), ok=False)                                # filler: desync
    add(F.build_slot(0, 0x0000, rng.randbytes(1984)))                 # full frame
    add(F.build_slot(1, 0x1000, rng.randbytes(32)))                   # one word
    add(F.build_slot(2, 0x2000, rng.randbytes(17 * 32 - 5)))          # short, padded
    add(F.poll_slot())                                                # poll: header only
    add(F.range_crc_slot(3, 0x0, 4096))                               # range request
    s = bytearray(F.build_slot(4, 0x3000, rng.randbytes(1984))); s[777] ^= 0x10
    add(bytes(s))                                                     # payload bit flip
    s = bytearray(F.build_slot(5, 0x4000, rng.randbytes(64))); s[F.CRC_OFFSET] ^= 1
    add(bytes(s))                                                     # CRC bit flip
    s = bytearray(F.build_slot(6, 0x5000, rng.randbytes(64))); s[0] ^= 0x80
    add(bytes(s), ok=False)                                           # wrong magic
    for k in range(8):                                                # back to back
        add(F.build_slot(7 + k, 0x6000 + 0x800 * k, rng.randbytes(rng.randrange(32, 1985))))
    with open(sim("jc_frame_vec.txt"), "w") as f:
        for s, ok, nw, ps, seq in slots:
            f.write("S %d %d %d %08x %s\n" % (ok, nw, ps, seq, F.slot_hex(s)))

def gen_writer(rng):
    """Events fed straight into the writer's FIFO port, plus the model's final state."""
    from jc import jc_frame as F
    from jc.jc_model import LoaderModel
    bad = 0x0600                                # the third burst of the first full frame
    m = LoaderModel(bad_bresp_addrs={bad})
    ev, slots = [], []
    def frame(seq, addr, payload, corrupt=False):
        s = F.build_slot(seq, addr, payload)
        if corrupt:
            s = bytearray(s); s[50] ^= 1; s = bytes(s)
        slots.append(s)
    frame(0, 0x0000, rng.randbytes(1984))       # 4 bursts, one SLVERR at 0x600
    frame(1, 0x0FE0, rng.randbytes(96))         # crosses 4 KB: bursts of 1 then 2
    frame(1, 0x0FE0, rng.randbytes(96))         # duplicate
    frame(3, 0x2000, rng.randbytes(64))         # gap
    frame(2, 0x3000, rng.randbytes(64), corrupt=True)   # CRC fail
    frame(2, 0x3000, rng.randbytes(1000))       # short, padded last word
    slots.append(F.poll_slot())
    for s in slots:
        m.feed(s)
        h = F.parse_header(s)
        ev.append("H %064x" % int.from_bytes(s[:32], "little"))
        for k in range(h["nwords"]):
            ev.append("D %064x" % int.from_bytes(s[32 * (k + 1):32 * (k + 2)], "little"))
        ev.append("%s %08x" % ("P" if F.slot_crc_ok(s) else "F", h["seq"]))

    # Fix round 2 (I1): a lost-verdict case where the displacing header differs from the
    # orphan in BOTH address and seq. Every existing lost-verdict case in this generator
    # (and in gen_loader_ovf) happens to have an orphan identical to its displacer, which
    # let a mutant that keeps the ORPHAN's h_seq/h_addr/h_nw/h_flags/h_rlen on this branch
    # (instead of loading the new header) survive both benches undetected: with an
    # identical orphan/displacer there is nothing those stale fields could get wrong.
    #
    # seq 50 / addr 0x9000, 10 words: sent as a header plus only 4 of its 10 data words,
    # then abandoned -- no verdict ever arrives for it, exactly the shape a dropped verdict
    # or a dropped tail of data words leaves behind. `last` is one less than this is correct
    # for after the frames above, since the earlier `frame(3, ...)` was a sequence gap and
    # never committed, so seq 3 is free to reuse here. SAME nwords (10) as the orphan, so
    # the word-count check at the verdict cannot by itself distinguish correct code from
    # the mutant -- only loading the NEW header's seq/addr can.
    orphan_seq, orphan_addr, nwords = 50, 0x9000, 10
    orphan = F.build_slot(orphan_seq, orphan_addr, rng.randbytes(nwords * 32))
    ev.append("H %064x" % int.from_bytes(orphan[:32], "little"))
    for k in range(4):                                  # partial: 4 of 10, no verdict
        ev.append("D %064x" % int.from_bytes(orphan[32 * (k + 1):32 * (k + 2)], "little"))
    disp_seq, disp_addr = 3, 0xA000
    disp = F.build_slot(disp_seq, disp_addr, rng.randbytes(nwords * 32))
    ev.append("H %064x" % int.from_bytes(disp[:32], "little"))
    for k in range(nwords):
        ev.append("D %064x" % int.from_bytes(disp[32 * (k + 1):32 * (k + 2)], "little"))
    ev.append("%s %08x" % ("P" if F.slot_crc_ok(disp) else "F", disp_seq))
    m.crc_fail += 1          # the lost verdict itself: LoaderModel has no per-event notion
                              # of an abandoned, never-completed frame, only per-slot feed()
    m.feed(disp)              # the displacing frame commits normally

    st = m.status()
    with open(sim("jc_writer_vec.txt"), "w") as f:
        f.write("B %010x\n" % bad)
        f.write("\n".join(ev) + "\n")
        for a in sorted(m.mem):
            f.write("M %010x %064x\n" % (a, int.from_bytes(m.mem[a], "little")))
        f.write("N %010x\n" % orphan_addr)   # must never have been written (ruling 6: the
                                              # orphan's partial data is discarded whole)
        f.write("C %08x %08x %04x %04x %04x %04x\n" % (st["last"], st["committed"],
                st["crc_fail"], st["seq_err"], st["dup"], st["bresp_err"]))

# jc_axi3_mem's BAD_RRESP_ADDR in the tb_jc_hbm_crc instantiation: a single-beat read
# starting here comes back with RRESP = SLVERR on every beat of that burst. Lies inside
# the 0x2000 preload base (word 8 of 70) so the data is real, only the response is bad.
JC_CRCUNIT_BAD_ADDR = 0x2100

def gen_crcunit(rng):
    """Preloaded memory plus range requests with zlib CRCs over the same bytes."""
    words = {}
    for base in (0x0000, 0x0FC0, 0x2000):
        for k in range(70):
            words[base + 32 * k] = rng.randbytes(32)
    reqs = [(0x0000, 32, 1, 0), (0x0000, 70 * 32, 2, 0), (0x0FC0, 5 * 32, 3, 0),  # 5 beats across 4 KB
            (0x2000, 16 * 32, 4, 0), (0x2000, 17 * 32, 5, 0), (0x2000, 0, 6, 0),  # 0 bytes: CRC of nothing
            (JC_CRCUNIT_BAD_ADDR, 32, 7, 1)]                                      # RRESP error expected
    with open(sim("jc_crcunit_vec.txt"), "w") as f:
        for a in sorted(words):
            f.write("M %010x %064x\n" % (a, int.from_bytes(words[a], "little")))
        for a, n, seq, experr in reqs:
            data = b"".join(words.get(x, bytes(32)) for x in range(a, a + n, 32))
            f.write("R %010x %010x %08x %08x %d\n" %
                    (a, n, seq, zlib.crc32(data) & 0xFFFFFFFF, experr))

def gen_loader(rng):
    """One continuous scan as the host sends it, plus the model's final memory and status.

    Addressing (fix round 1, M3): frames are spaced 0x1000 (4 KB) apart, which is more than
    any frame's 1,984-byte max payload, so no two of these frames ever write the same byte
    and the per-address memory check below cannot be hidden by a later frame overwriting an
    earlier one's bytes. The OLD 0x0400 spacing was narrower than the max payload, so
    adjacent frames silently overlapped; the memory check still passed because it only
    checks presence/value at addresses the LAST writer of each address produced, never
    noticing an earlier frame's bytes were never checked at all.

    k=5 is reserved for a frame that deterministically crosses a 4 KB boundary: its address
    (0xC000 + 0x0FE0, i.e. 0x0FE0 into an otherwise-unused 4 KB page) and its length (a FIXED
    64 bytes = 2 words, not the random draw used for the other 11) are both independent of
    the RNG, so the crossing happens every run. The OLD `0x0400*k + 0x0FE0 if k==5` line
    landed at 0x23E0, which is 0xC20 bytes short of the next 4 KB boundary (0x3000) -- more
    than the 1,984-byte max payload, so it could never actually cross 4 KB regardless of the
    random length; the "k=5 crosses 4 KB" comment on it was simply wrong.
    """
    from jc import jc_frame as F
    from jc.jc_model import LoaderModel
    m = LoaderModel()
    slots = [bytes(F.SLOT_BYTES)]                                     # filler (lead = 0)
    seq = 0
    for k in range(12):
        if k == 5:
            addr = 0xC000 + 0x0FE0          # dedicated page, clear of every other frame's
                                             # span; fixed length below guarantees the crossing
            payload = rng.randbytes(64)
        else:
            addr = 0x1000 * k
            payload = rng.randbytes(rng.randrange(32, 1985))
        slots.append(F.build_slot(seq, addr, payload)); seq += 1
    bad = bytearray(F.build_slot(seq, 0xE000, rng.randbytes(500))); bad[999] ^= 2
    slots.append(bytes(bad))                                          # CRC fail
    slots.append(F.build_slot(seq, 0xE000, rng.randbytes(500))); seq += 1   # resend
    slots.append(F.build_slot(seq - 1, 0xE000, rng.randbytes(500)))   # duplicate
    # Fix round 2 (M4): 0x0000..0x1020 -- all of frame k=0's real data (up to 0x07C0),
    # the zero padding out to k=1's page (0x1000), and the first 32 bytes (one word) of
    # k=1's real payload. k=1's payload is never shorter than 32 bytes (rng.randrange's
    # floor above), so this always crosses into genuine data from a SECOND frame
    # regardless of the random length drawn for either frame, instead of the old
    # 0x0000..0x0C00 range, which (after M3's 0x1000 spacing) covered only k=0's data
    # plus unwritten zeros and never reached a second frame at all.
    slots.append(F.range_crc_slot(seq, 0x0000, 0x1000 + 0x20)); seq += 1
    slots += [F.poll_slot()] * 3
    for s in slots:
        m.feed(s)
    st = m.status()
    with open(sim("jc_loader_vec.txt"), "w") as f:
        for s in slots:
            f.write("S %s\n" % F.slot_hex(s))
        for a in sorted(m.mem):
            f.write("M %010x %064x\n" % (a, int.from_bytes(m.mem[a], "little")))
        f.write("T %08x %08x %04x %04x %04x %04x %08x %08x\n" % (
            st["last"], st["committed"], st["crc_fail"], st["seq_err"], st["dup"],
            st["desync"], st["range_crc"], st["range_seq"]))

def gen_loader_ovf(rng):
    """End-to-end FIFO-overflow case (fix round 1, I1): the host sends six real frames and
    one resend while the testbench holds the AXI3 AW channel closed across four of them, long
    enough that the 128-deep async_fifo genuinely overflows (status bit 179) -- not merely a
    writer that is slow, a case already covered by sim/tb_jc_loader_core.vhd's STALL=>true.

    Frame layout (seq, addr, nwords), with gate (AW channel) state during each. Addresses are
    spaced 0x800 apart (more than the 1,984-byte max payload of any frame here), so -- same
    reasoning as M3 for gen_loader -- no two frames ever write the same byte and the memory
    check below cannot be hidden by a later frame overwriting an earlier one's bytes:
      seq0 addr 0x0000 nwords 62   gate OPEN   -- commits before the block starts
      seq1 addr 0x0800 nwords 62   gate closes AFTER this frame's header+data+verdict are
                                   collected (collection does not need AW); the WRITE decision
                                   for this frame is what gets stuck
      seq2 addr 0x1000 nwords 62   gate CLOSED -- queues whole (64 FIFO entries: hdr+62 data+
                                   verdict); writer is stuck on seq1's AW, so nothing drains
      seq3 addr 0x1800 nwords 61   gate CLOSED -- queues whole (63 entries). FIFO level is now
                                   64 + 63 = 127.
      seq4 addr 0x2000 nwords 62   gate CLOSED -- only its HEADER and its first TWO DATA
                                   words fit (level 127 -> 130); the real push-side capacity
                                   here is 130, not the 128-entry DEPTH generic, because
                                   rtl/async_fifo.vhd's 2-entry read-side output stage
                                   (`ob`) prefetches from `mem` independently of whether the
                                   writer is ready, so up to 2 beats the writer has not
                                   consumed yet already read as "free" to the write side
                                   (see FifoOverflowModel's docstring in jc_model.py for the
                                   full mechanism). Every other word of this frame (the
                                   remaining 60 data words + 1 verdict, 61 total) arrives at
                                   a now-full FIFO and is DROPPED. This sets status bit 179
                                   (ovf). MEASURED (a temporary per-slot accept/drop probe in
                                   a scratch jc_frame_core.vhd, fix round 2): accepts 3,
                                   drops 61. Gate reopens right after this frame's slot ends.
                                   The final status/memory below (the T line) is INVARIANT
                                   to the exact capacity over a wide range -- MEASURED (the
                                   reviewer, confirmed independently against this same model
                                   by sweeping FifoOverflowModel's depth) 128..190 total
                                   capacity all give the identical T line; this is not a
                                   knife edge pinned to 130.
      seq4 RESEND addr 0x2000     gate OPEN -- by the time this is shifted in, the writer has
                                   already (in aclk time, far faster than one TCK slot) drained
                                   the backlog: finished seq1's write, drained and committed
                                   seq2 and seq3 in order, and popped seq4's orphan header into
                                   its S_COLLECT state with nothing behind it. This resend's own
                                   header is therefore the FIFO's very next entry while the
                                   writer is already mid-collect on the dead seq4 header -- this
                                   is jc_hbm_writer's "lost verdict" branch (S_COLLECT sees a
                                   second TAG_HDR with no intervening verdict): counted as a
                                   CRC failure per ruling 6, then collection restarts cleanly on
                                   the resend's own header and the resend commits normally.
      seq5 addr 0x2800 nwords 62   gate OPEN -- commits normally

    This is the SAME mechanism ruling 6 describes for a word-count mismatch (a frame whose
    FIFO entries were partly dropped), reached here through the FIFO drop landing exactly on
    a verdict rather than a data word -- the dropped frame's header is the only piece that
    survives, so the writer never gets a verdict for it at all and instead treats the next
    arriving header as the one that must have displaced it.

    The expected final status/memory is produced by FifoOverflowModel (jc_model.py), an
    explicit simulation of the FIFO's bounded queue plus the writer's S_HDR/S_COLLECT/S_DECIDE
    states at FIFO-entry granularity, independent of the RTL. It was cross-checked against an
    actual GHDL run of the composed core with this exact frame/gate schedule during
    development (see task-6-report.md, "Fix round 1"); the vector file commits only this
    model's derived values, never a value copied from the RTL's own printed status.
    """
    from jc import jc_frame as F
    from jc.jc_model import FifoOverflowModel
    m = FifoOverflowModel(depth=128)
    slots = [bytes(F.SLOT_BYTES)]                                    # filler (lead = 0)
    m.feed_slot(slots[-1])

    frames = [(0, 0x0000, 62), (1, 0x0800, 62), (2, 0x1000, 62), (3, 0x1800, 61),
              (4, 0x2000, 62)]
    m.set_gate(True)
    for seq, addr, nwords in frames:
        s = F.build_slot(seq, addr, rng.randbytes(nwords * 32))
        slots.append(s)
        if seq == 1:
            m.set_gate(False)         # close right before this frame's entries are pushed
        m.feed_slot(s)
        if seq == 4:
            m.set_gate(True)          # reopen right after the lost frame's slot completes

    s = F.build_slot(4, 0x2000, rng.randbytes(62 * 32))               # resend
    slots.append(s); m.feed_slot(s)
    s = F.build_slot(5, 0x2800, rng.randbytes(62 * 32))
    slots.append(s); m.feed_slot(s)
    slots += [F.poll_slot()] * 3
    for s in slots[-3:]:
        m.feed_slot(s)

    st = m.status()
    with open(sim("jc_loader_ovf_vec.txt"), "w") as f:
        for s in slots:
            f.write("S %s\n" % F.slot_hex(s))
        for a in sorted(m.mem):
            f.write("M %010x %064x\n" % (a, int.from_bytes(m.mem[a], "little")))
        f.write("T %08x %08x %04x %04x %04x %04x %d\n" % (
            st["last"], st["committed"], st["crc_fail"], st["seq_err"], st["dup"],
            st["desync"], st["ovf"]))

GENS = {"crc32": gen_crc32, "frame": gen_frame, "writer": gen_writer, "crcunit": gen_crcunit,
        "loader": gen_loader, "loader_ovf": gen_loader_ovf}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=sorted(GENS))
    a = ap.parse_args()
    for name, fn in GENS.items():
        if a.only and name != a.only:
            continue
        fn(random.Random(20261005))
        print("wrote", name)

if __name__ == "__main__":
    main()
