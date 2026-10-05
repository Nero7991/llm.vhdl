import json, os, sys, zlib, hashlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe_load as L, jc_frame as F

def make_manifest(tmp_path, sizes):
    files = []
    off = 0
    for i, n in enumerate(sizes):
        data = bytes((i * 7 + k) & 0xFF for k in range(n))
        p = tmp_path / ("t%d.bin" % i)
        p.write_bytes(data)
        files.append(dict(file=p.name, kind="f32blob", tensor="t%d" % i, nbytes=n,
                          hbm_offset=off, stack=0,
                          blake2b_128=hashlib.blake2b(data, digest_size=16).hexdigest()))
        off += (n + 4095) // 4096 * 4096
    m = dict(format="test", geometry={"rows_if": 48, "axi_dw": 256}, hbm={}, files=files)
    mp = tmp_path / "manifest.json"
    mp.write_text(json.dumps(m))
    return str(mp)

def make_single_piece_manifest(tmp_path, hbm_offset, nbytes, stack=None):
    data = bytes((k * 5 + 1) & 0xFF for k in range(nbytes))
    p = tmp_path / "p.bin"
    p.write_bytes(data)
    e = dict(file="p.bin", kind="f32blob", tensor="p", nbytes=nbytes, hbm_offset=hbm_offset,
             blake2b_128=hashlib.blake2b(data, digest_size=16).hexdigest())
    if stack is not None:
        e["stack"] = stack
    m = dict(format="test", geometry={}, hbm={}, files=[e])
    mp = tmp_path / "manifest.json"
    mp.write_text(json.dumps(m))
    return str(mp)

def make_two_piece_manifest(tmp_path, n0, n1):
    """One file holding two pieces back-to-back in the FILE but far apart in HBM, the
    shape a lane-striped v2 manifest uses (tools/hbm_map.py::file_pieces)."""
    total = n0 + n1
    data = bytes((k * 11 + 3) & 0xFF for k in range(total))
    p = tmp_path / "striped.bin"
    p.write_bytes(data)
    pieces = [dict(hbm_offset=0, file_offset=0, nbytes=n0),
              dict(hbm_offset=4096, file_offset=n0, nbytes=n1)]
    e = dict(file="striped.bin", kind="f32blob", tensor="s", nbytes=total, hbm_offset=0,
             stack=0, blake2b_128=hashlib.blake2b(data, digest_size=16).hexdigest(),
             pieces=pieces)
    m = dict(format="test", geometry={}, hbm={}, files=[e])
    mp = tmp_path / "manifest.json"
    mp.write_text(json.dumps(m))
    return str(mp), data

def test_plan_covers_every_byte_once(tmp_path):
    mp = make_manifest(tmp_path, [5000, 64, 4096])
    frames, sha = L.plan_frames(mp)
    data = [f for f in frames if f.kind == "data"]
    assert [f.seq for f in frames] == list(range(len(frames)))
    assert sum(f.n for f in data) == 5000 + 64 + 4096
    assert all(f.n <= F.MAX_PAYLOAD_BYTES and f.addr % 32 == 0 for f in data)
    assert [f for f in frames if f.kind == "range"]               # one per piece, at the end

def test_odd_length_piece_pads_inside_its_own_4k(tmp_path):
    mp = make_manifest(tmp_path, [1000, 64])
    frames, _ = L.plan_frames(mp)
    last0 = max((f for f in frames if f.kind == "data" and f.path.endswith("t0.bin")),
                key=lambda f: f.addr)
    end_padded = last0.addr + (last0.n + 31) // 32 * 32
    assert end_padded <= 4096                                      # never reaches t1 at 4096
    rng = [f for f in frames if f.kind == "range" and f.addr == 0][0]
    assert rng.n == 1024                                           # 1000 rounded up to 32
    assert L.expected_range_crc(rng) == zlib.crc32(open(rng.path, "rb").read() + bytes(24)) & 0xFFFFFFFF

def test_plan_refuses_a_changed_file(tmp_path):
    mp = make_manifest(tmp_path, [64])
    (tmp_path / "t0.bin").write_bytes(b"\xFF" * 64)
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_sha_changes_with_the_manifest(tmp_path):
    a = make_manifest(tmp_path, [64])
    _, s1 = L.plan_frames(a)
    b = make_manifest(tmp_path, [96])
    _, s2 = L.plan_frames(b)
    assert s1 != s2

# ---------------------------------------------------------------- fix round 1: (c)

def test_range_crc_pads_with_zero_not_the_next_piece(tmp_path):
    """The bug the review found: a short piece's range CRC used to be computed by
    reading `n` (the 32-byte-rounded length) bytes straight out of the source file,
    which -- when a second piece's bytes happen to sit right after it in the same file
    -- pulls in real neighbour data instead of the zero padding the card actually
    holds (jc_frame.build_slot zero-pads a frame's payload; jc_hbm_writer commits whole
    words). expected_range_crc must now pad with zero itself, using the piece's own
    unpadded length (`raw_n`)."""
    mp, data = make_two_piece_manifest(tmp_path, 1000, 1048)
    frames, _ = L.plan_frames(mp)
    r0 = [f for f in frames if f.kind == "range" and f.addr == 0][0]
    assert r0.n == 1024 and r0.raw_n == 1000
    assert L.expected_range_crc(r0) == zlib.crc32(data[:1000] + bytes(24)) & 0xFFFFFFFF
    assert L.expected_range_crc(r0) != zlib.crc32(data[:1024]) & 0xFFFFFFFF  # the old, wrong answer

# ---------------------------------------------------------------- fix round 1: (d)

def test_plan_sha_changes_when_only_the_content_digest_changes(tmp_path):
    """Same file name, same address, same size -- only the bytes (and so the manifest's
    blake2b_128) differ. The old plan_sha hashed only (file, addr, file_offset, nbytes)
    and could not tell."""
    p = tmp_path / "t0.bin"
    mp = tmp_path / "manifest.json"
    data_a = bytes(64)
    p.write_bytes(data_a)
    e = dict(file="t0.bin", kind="f32blob", tensor="t0", nbytes=64, hbm_offset=0, stack=0,
             blake2b_128=hashlib.blake2b(data_a, digest_size=16).hexdigest())
    mp.write_text(json.dumps(dict(format="test", geometry={}, hbm={}, files=[e])))
    _, s1 = L.plan_frames(str(mp))

    data_b = bytes(range(64))
    p.write_bytes(data_b)
    e["blake2b_128"] = hashlib.blake2b(data_b, digest_size=16).hexdigest()
    mp.write_text(json.dumps(dict(format="test", geometry={}, hbm={}, files=[e])))
    _, s2 = L.plan_frames(str(mp))
    assert s1 != s2

def test_plan_sha_changes_with_the_die(tmp_path):
    mp = make_manifest(tmp_path, [64])
    _, sa = L.plan_frames(mp, die="A")
    _, sb = L.plan_frames(mp, die="B")
    assert sa != sb

# ---------------------------------------------------------------- fix round 1: (e)

def test_plan_refuses_a_piece_past_the_hbm_map(tmp_path):
    mp = make_single_piece_manifest(tmp_path, L.HBM_SIZE - 32, 64)   # 64 B, starts 32 B before the top
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_refuses_a_piece_crossing_the_stack_boundary(tmp_path):
    mp = make_single_piece_manifest(tmp_path, L.STACK_LINE - 32, 64)
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_refuses_a_wrong_declared_stack(tmp_path):
    mp = make_single_piece_manifest(tmp_path, 0, 64, stack=1)        # addr 0 is stack 0
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_refuses_a_zero_length_piece(tmp_path):
    mp = make_single_piece_manifest(tmp_path, 0, 0)
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

# ---------------------------------------------------------------- fix round 2: (6)

def make_pieces_manifest(tmp_path, pieces, nbytes=None, stack=None, filedata=None):
    data = filedata if filedata is not None else bytes((k * 5 + 1) & 0xFF for k in range(64))
    p = tmp_path / "p.bin"
    p.write_bytes(data)
    e = dict(file="p.bin", kind="f32blob", tensor="p",
             nbytes=nbytes if nbytes is not None else len(data),
             hbm_offset=pieces[0]["hbm_offset"],
             blake2b_128=hashlib.blake2b(data, digest_size=16).hexdigest(),
             pieces=pieces)
    if stack is not None:
        e["stack"] = stack
    m = dict(format="test", geometry={}, hbm={}, files=[e])
    mp = tmp_path / "manifest.json"
    mp.write_text(json.dumps(m))
    return str(mp)

def test_declared_stack_checks_the_header_only_not_every_piece(tmp_path):
    """A real lane-striped object: header (and declared stack) in stack 0, but some
    lanes legitimately placed in stack 1 -- 12 of 27 lanes do, by design, on a real
    manifest. tools/hbm_map.py's own P4 check (manifest_piece_fails) compares the
    declared `stack` against the HEADER (the object's own hbm_offset) only;
    plan_frames must agree, not refuse every striped object that uses both stacks (the
    old per-piece check refused 1,488 of 3,473 pieces on qwen35-9b-card0-b0-15-nh)."""
    pieces = [dict(hbm_offset=0, file_offset=0, nbytes=32),
              dict(hbm_offset=L.STACK_LINE + 4096, file_offset=32, nbytes=32)]
    mp = make_pieces_manifest(tmp_path, pieces, nbytes=64, stack=0)
    frames, _ = L.plan_frames(mp)                          # must not raise
    assert frames

def test_declared_stack_is_still_checked_against_the_header_in_a_striped_manifest(tmp_path):
    """The header itself (not a lane) disagreeing with the declared stack must still
    be refused, striped shape or not."""
    pieces = [dict(hbm_offset=0, file_offset=0, nbytes=32),
              dict(hbm_offset=L.STACK_LINE + 4096, file_offset=32, nbytes=32)]
    mp = make_pieces_manifest(tmp_path, pieces, nbytes=64, stack=1)  # header is really stack 0
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_passes_on_a_real_lane_striped_manifest():
    """qwen35-9b-card0-b0-15-nh: blk.14.ffn_down.weight.mv4i alone has 12 of its 28
    pieces in stack 1 while declaring stack 0 (its header's own stack) -- the exact
    shape the old per-piece check refused. Read-only; found with `ls` under
    /mnt/storage/llama-models/, not written to."""
    manifest = "/mnt/storage/llama-models/qwen35-9b-card0-b0-15-nh/manifest.json"
    if not os.path.exists(manifest):
        pytest.skip("real manifest not present on this host")
    frames, _ = L.plan_frames(manifest, die="A")
    assert frames

# ---------------------------------------------------------------- fix round 2: (7)

def test_plan_refuses_a_negative_hbm_address(tmp_path):
    mp = make_pieces_manifest(tmp_path, [dict(hbm_offset=-64, file_offset=0, nbytes=64)])
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_refuses_a_negative_file_offset(tmp_path):
    mp = make_pieces_manifest(tmp_path, [dict(hbm_offset=0, file_offset=-64, nbytes=64)])
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_refuses_a_piece_past_the_files_own_size(tmp_path):
    data = bytes(2048)
    mp = make_pieces_manifest(tmp_path, [dict(hbm_offset=0, file_offset=2000, nbytes=1000)],
                               nbytes=1000, filedata=data)
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

# ======================================================================
# Task 9: pipelined load with resync, settled-status completion, resume and verify.
# LoaderModel (jc_model.py, independent of the RTL and of coe_load.py) is the oracle
# for what the die holds. No test here may open a real socket: the autouse fixture
# below makes any attempt fail loudly, and every CoE client is built on a fake socket.
# ======================================================================
import struct
from jc.jc_model import LoaderModel
from jc import coe

@pytest.fixture(autouse=True)
def _no_real_sockets(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("a test tried to open a real socket: %r" % (a,))
    monkeypatch.setattr(coe.socket, "create_connection", refuse)

def plan(tmp_path, sizes=(5000, 64, 4096)):
    return L.plan_frames(make_manifest(tmp_path, list(sizes)))

def assert_die_holds_the_plan(m, frames):
    for fr in (f for f in frames if f.kind == "data"):
        raw = L.read_payload(fr)
        for k in range(0, fr.n, 32):
            assert m.mem[fr.addr + k] == raw[k:k + 32].ljust(32, b"\0")

def test_clean_load_matches_the_file_bytes(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=1)
    st = L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert st["last"] == frames[-1].seq and st["busy"] == 0
    assert_die_holds_the_plan(m, frames)
    assert m.crc_fail == m.seq_err == 0

def test_resync_after_crc_failure_with_pipeline(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=0, fail_seqs={2})
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq
    assert ld.resyncs == 1 and st["crc_fail"] == 1
    assert_die_holds_the_plan(m, frames)

def test_completion_waits_for_status(tmp_path):
    frames, sha = plan(tmp_path, (64,))
    t = L.FakeTransport(LoaderModel(), lead=1, lag_slots=4)
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and st["busy"] == 0
    assert ld.resyncs == 0                     # waited for the lagged status, resent nothing

def test_wrong_chain_position_aborts_fast(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, wrong_lead=True)
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    with pytest.raises(L.LoadAborted, match="chain"):
        ld.run_load()
    assert t.sent < 64

def test_resume_continues_from_fpga_status(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    t = L.FakeTransport(m, lead=1, drop_after=16)
    with pytest.raises(ConnectionError):
        L.Loader(t, frames, sha, ck).run_load()
    committed = m.last
    assert committed != 0xFFFFFFFF and committed < frames[-1].seq   # a partial load
    t2 = L.FakeTransport(m, lead=1)
    st = L.Loader(t2, frames, sha, ck, resume=True).run_load()
    assert st["last"] == frames[-1].seq
    assert t2.first_seq_sent == committed + 1
    assert_die_holds_the_plan(m, frames)

def test_resume_refuses_other_plan(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    t = L.FakeTransport(m, lead=1, drop_after=16)
    with pytest.raises(ConnectionError):
        L.Loader(t, frames, sha, ck).run_load()
    t2 = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="plan"):
        L.Loader(t2, frames, "0" * 64, ck, resume=True).run_load()
    assert t2.sent == 0                         # refused before touching the board

def test_verify_reports_a_corrupted_word(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    m.mem[0x40] = b"\xEE" * 32
    bad = L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck2.json")).run_verify()
    assert len(bad) == 1 and bad[0][0].addr == 0
    fr, got, want = bad[0]
    assert want == L.expected_range_crc(fr) and got != want

# ---------------------------------------------------------------- beyond the brief

def test_verify_of_a_clean_load_passes_under_a_long_status_lag(tmp_path):
    """The brief's verify settled on two equal statuses; under a lag, the polls left over
    from the previous piece produce two equal STALE statuses, so it read the previous
    range result (or aborted). Verify must wait for its own range_seq."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    L.Loader(L.FakeTransport(m, lead=1, lag_slots=4), frames, sha, str(tmp_path / "ck.json")).run_load()
    bad = L.Loader(L.FakeTransport(m, lead=1, lag_slots=4), frames, sha,
                   str(tmp_path / "ck2.json")).run_verify()
    assert bad == []

def test_dropped_frame_mid_stream_is_resent(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = L.Loader(L.FakeTransport(m, lead=1, drop_seqs={3}), frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1 and m.seq_err > 0
    assert_die_holds_the_plan(m, frames)

def test_dropped_last_frame_is_resent_after_the_completion_wait(tmp_path):
    """Nothing after the last frame can raise a counter: completion must notice the
    tail never committed and resend it."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = L.Loader(L.FakeTransport(m, lead=1, drop_seqs={frames[-1].seq}), frames, sha,
                  str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert_die_holds_the_plan(m, frames)

def test_desync_slot_triggers_resync(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = L.Loader(L.FakeTransport(m, lead=0, desync_seqs={4}), frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert_die_holds_the_plan(m, frames)

def test_link_fault_recovers_with_recover_then_reopen(tmp_path):
    """A bad CoE reply mid-pipeline (LinkFault): the loader must call recover() (drain
    then resync on the real transport), never close_scan() with replies unread. The
    fake refuses any other order with AssertionError."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=1, fault_sends={5})
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1 and t.recovers == 1
    assert_die_holds_the_plan(m, frames)

def test_link_faults_are_bounded(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, fault_sends=set(range(4, 10000)))
    with pytest.raises(L.LoadAborted, match="resyncs"):
        L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert t.recovers <= L.MAX_RESYNCS

def test_repeated_crc_failures_are_bounded(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, fail_seqs={2}, fail_forever=True)
    with pytest.raises(L.LoadAborted, match="resyncs"):
        L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()

def test_fresh_load_refuses_a_die_that_already_holds_frames(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    with pytest.raises(ConnectionError):
        L.Loader(L.FakeTransport(m, lead=1, drop_after=16), frames, sha, str(tmp_path / "ck.json")).run_load()
    with pytest.raises(L.LoadAborted, match="resume"):
        L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()

def test_resume_without_a_checkpoint_is_refused(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(L.LoadAborted, match="checkpoint"):
        L.Loader(t, frames, sha, str(tmp_path / "none.json"), resume=True).run_load()
    assert t.sent == 0

def test_checkpoint_records_plan_and_progress(tmp_path):
    frames, sha = plan(tmp_path)
    ck = tmp_path / "ck.json"
    L.Loader(L.FakeTransport(LoaderModel(), lead=1), frames, sha, str(ck)).run_load()
    d = json.loads(ck.read_text())
    assert d["plan_sha"] == sha and d["last"] == frames[-1].seq

def test_hbm_temperature_trip_aborts(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=0, lag_slots=0, trip_after=4)
    with pytest.raises(L.LoadAborted, match="temperature"):
        L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()

def test_hbm_write_response_error_aborts(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(bad_bresp_addrs={0})
    with pytest.raises(L.LoadAborted, match="BRESP"):
        L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()

def test_loader_refuses_frames_out_of_seq_order(tmp_path):
    frames, sha = plan(tmp_path)
    with pytest.raises(ValueError):
        L.Loader(L.FakeTransport(LoaderModel(), lead=1), frames[1:], sha, str(tmp_path / "ck.json"))

# ---------------------------------------------------------------- CoeTransport, modelled chain

class ChainSock:
    """A fake BMC socket in front of a modelled two-die JTAG chain (TDI -> device 0 ->
    device 1 -> TDO). It runs an IEEE 1149.1 TAP per TCK, a 12-bit IR per device
    (Test-Logic-Reset loads IDCODE), a 1-bit BYPASS register, and, on the device at
    `loader_pos` while its IR is USER4, the slot-counting receiver of
    rtl/jc_frame_core.vhd: Capture-DR resets the bit counter and loads the status
    shift register; every 16,384 bits is one slot, fed to a LoaderModel; the status
    register reloads at every slot boundary and shifts out LSB first, one bit per TCK
    (TDO = st_sr(0)). The other die has no loader: USER4 on it drives TDO low.

    Every Update-IR value is recorded; any one off the allowlist, a CMD_TDI outside
    Shift-DR, or a CMD_TDI shift under an instruction other than BYPASS/USER4 is
    recorded as a violation. `bad_status_tdi` makes the n-th CMD_TDI reply carry a bad status
    (its bits are still shifted); `flip_seqs` corrupts one bit of that frame once."""
    def __init__(s, model, loader_pos, lag=1, bad_status_tdi=(), flip_seqs=(),
                 start=coe.TEST_LOGIC_RESET):
        s.m, s.pos, s.lag = model, loader_pos, lag
        s.bad, s.flip = set(bad_status_tdi), set(flip_seqs)
        s.state = start
        s.ir = [coe.IR_IDCODE, coe.IR_IDCODE]
        s.irsr = [0, 0]
        s.byp = [0, 0]
        s.bitcnt, s.acc, s.st_sr, s.sthist = 0, 0, 0, []
        s.q, s.ntdi = b"", 0
        s.ir_updates, s.violations = [], []

    def setsockopt(s, *a):
        pass

    def _status(s):
        s.sthist.append(dict(s.m.status()))
        return int.from_bytes(F.pack_status(s.sthist[max(0, len(s.sthist) - 1 - s.lag)]), "little")

    def _core(s, n, x):
        out, i = 0, 0
        while i < n:
            take = min(n - i, F.SLOT_BITS - s.bitcnt)
            out |= (s.st_sr & ((1 << take) - 1)) << i
            s.st_sr >>= take
            s.acc |= ((x >> i) & ((1 << take) - 1)) << s.bitcnt
            s.bitcnt += take
            i += take
            if s.bitcnt == F.SLOT_BITS:
                slot = s.acc.to_bytes(F.SLOT_BYTES, "little")
                h = F.parse_header(slot)
                if h["magic"] == F.MAGIC_FRAME and h["seq"] in s.flip and (h["nwords"] or h["flags"]):
                    s.flip.discard(h["seq"])
                    b = bytearray(slot); b[100] ^= 1; slot = bytes(b)
                s.m.feed(slot)
                s.st_sr = s._status()
                s.bitcnt, s.acc = 0, 0
        return out

    def _dev(s, d, n, x, tdi_cmd=False):
        if s.ir[d] == coe.IR_USER4:
            return s._core(n, x) if d == s.pos else 0
        if tdi_cmd and s.ir[d] != coe.IR_BYPASS:
            # resync() legitimately passes Shift-DR under any IR (TDI=1); a CMD_TDI
            # shift under IDCODE etc. would misalign every slot, so that is flagged
            s.violations.append("CMD_TDI shift on device %d under IR %#x" % (d, s.ir[d]))
        out = (s.byp[d] | (x << 1)) & ((1 << n) - 1)
        s.byp[d] = (x >> (n - 1)) & 1
        return out

    def _dr(s, n, x, tdi_cmd=False):
        for d in range(2):
            x = s._dev(d, n, x, tdi_cmd)
        return x

    def _clock(s, tms, tdi):
        st = s.state
        if st == coe.SHIFT_DR:
            s._dr(1, tdi)
        elif st == coe.SHIFT_IR:
            o0 = s.irsr[0] & 1
            s.irsr[0] = (s.irsr[0] >> 1) | (tdi << 11)
            s.irsr[1] = (s.irsr[1] >> 1) | (o0 << 11)
        elif st == coe.CAPTURE_DR:
            for d in range(2):
                if d == s.pos and s.ir[d] == coe.IR_USER4:
                    s.bitcnt, s.acc, s.st_sr = 0, 0, s._status()
                else:
                    s.byp[d] = 0
        elif st == coe.CAPTURE_IR:
            s.irsr = [0x001, 0x001]
        nxt = coe.TAP_NEXT[st][tms]
        if nxt == coe.UPDATE_IR:
            s.ir = list(s.irsr)
            s.ir_updates.append(tuple(s.ir))
            for v in s.ir:
                if v not in coe.IR_ALLOW:
                    s.violations.append("Update-IR latched %#05x" % v)
        elif nxt == coe.TEST_LOGIC_RESET:
            s.ir = [coe.IR_IDCODE, coe.IR_IDCODE]
        s.state = nxt

    def sendall(s, b):
        L_, t, cmd = struct.unpack_from("<HHI", b)
        p, d, status = b[8:], b"", coe.STATUS_OK
        if cmd == coe.CMD_IDCODES:
            d = coe.VU35P_X2_IDCODES
        elif cmd == coe.CMD_TMS:
            n = struct.unpack_from("<H", p, 2)[0]
            for k in range(n):
                tdi = (p[4 + 2 * (k // 8)] >> (k % 8)) & 1
                tms = (p[5 + 2 * (k // 8)] >> (k % 8)) & 1
                s._clock(tms, tdi)
        elif cmd == coe.CMD_TDI:
            n = struct.unpack_from("<H", p, 2)[0]
            if s.state != coe.SHIFT_DR:
                s.violations.append("CMD_TDI with the real TAP in state %d" % s.state)
                y = 0
            else:
                y = s._dr(n, int.from_bytes(p[4:], "little"), tdi_cmd=True)
            d = y.to_bytes((n + 7) // 8, "little")
            if s.ntdi in s.bad:
                status = 0xDEAD0000
            s.ntdi += 1
        s.q += struct.pack("<HHI", 8 + len(d), t, status) + d

    def recv(s, n):
        r, s.q = s.q[:n], s.q[n:]
        return r

def chain_transport(model, die, chain, loader_pos, **kw):
    sock = ChainSock(model, loader_pos, **kw)
    client = coe.CoE(None, sock=sock)
    return L.CoeTransport(None, die, chain, client=client), sock, client

def assert_chain_clean(sock, client):
    assert sock.violations == []
    assert sock.ir_updates and all(v in coe.IR_ALLOW for u in sock.ir_updates for v in u)
    assert client.tap == coe.RUN_TEST_IDLE == sock.state and client.outstanding == []

@pytest.mark.parametrize("die,chain,pos", [("A", "AB", 0), ("B", "AB", 1), ("A", "BA", 1), ("B", "BA", 0)])
def test_coe_transport_loads_over_a_modelled_chain(tmp_path, die, chain, pos):
    """Both chain positions: the filler length (16384 - lead) and the status offset
    must line slots and status up on the real wire, through the real CoE client."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, die, chain, pos)
    assert t.lead == pos and t.status_offset == 1
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 0
    assert_die_holds_the_plan(m, frames)
    assert m.desync == 1 and m.crc_fail == 0              # exactly the one filler slot
    assert_chain_clean(sock, client)

def test_coe_transport_resyncs_after_a_crc_failure(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, "B", "AB", 1, flip_seqs={3})
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1 and m.crc_fail == 1
    assert_die_holds_the_plan(m, frames)
    assert_chain_clean(sock, client)

@pytest.mark.parametrize("bad_tdi", [6, 13])
def test_coe_transport_recovers_from_a_bad_reply_by_drain_then_resync(tmp_path, bad_tdi):
    """N2 through the loader. CMD_TDI 6 is a settle poll (nothing else in flight);
    CMD_TDI 13 is a pipelined frame with more shifts in flight behind it, so
    CoeTransport.recover() must drain() them before resync() (the client refuses
    resync() with replies unread), then re-select USER4 and resend."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, "A", "AB", 0, bad_status_tdi={bad_tdi})
    unread = []
    real_drain = client.drain
    def drain():
        unread.append(len(client.outstanding))
        return real_drain()
    client.drain = drain
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert unread == [0 if bad_tdi == 6 else t.depth - 1]
    assert_die_holds_the_plan(m, frames)
    assert_chain_clean(sock, client)

def test_coe_transport_wrong_chain_aborts(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, "A", "BA", 0)       # A is really at position 0
    with pytest.raises(L.LoadAborted, match="chain"):
        L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert m.committed == 0 and sock.violations == []

def test_coe_transport_verify_reports_a_corrupted_word(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, "B", "AB", 1)
    L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    m.mem[8192 + 0x20] = b"\x11" * 32                         # second word of t1 (64 B at 8192)
    t2, sock2, client2 = chain_transport(m, "B", "AB", 1)
    bad = L.Loader(t2, frames, sha, str(tmp_path / "ck2.json")).run_verify()
    assert [b[0].addr for b in bad] == [8192]
    assert_chain_clean(sock2, client2)

def test_coe_transport_does_not_turn_a_guard_refusal_into_a_link_fault(tmp_path):
    """A TapProtocolError is a refusal, not a link problem: it must propagate as-is so
    the loader aborts rather than 'recovering' around the guard."""
    m = LoaderModel()
    t, sock, client = chain_transport(m, "A", "AB", 0)
    client.tap = coe.UNKNOWN
    with pytest.raises(coe.TapProtocolError):
        t.open_scan()

def test_cli_requires_the_bmc_address_and_has_no_default(tmp_path):
    mp = make_manifest(tmp_path, [64])
    with pytest.raises(SystemExit) as e:
        L.main(["load", mp, "--die", "A", "--chain", "AB"])
    assert e.value.code == 2
    src = open(L.__file__).read()
    import re
    ips = set(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", src))
    assert ips <= {"192.0.2.1"}, ips

@pytest.mark.parametrize("fault", ["fail_seqs", "desync_seqs"])
def test_a_fault_on_the_last_frame_is_caught_by_its_counter_not_the_timeout(tmp_path, fault):
    """No later frame follows the last one to raise seq_err, so only its own counter
    (crc_fail or desync) can catch it promptly; without that, completion would sit out
    MAX_POLLS and resend the tail as if the frame had vanished."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = L.Loader(L.FakeTransport(m, lead=1, **{fault: {frames[-1].seq}}), frames, sha,
                  str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert ld.causes[0].startswith("error counters"), ld.causes
    assert_die_holds_the_plan(m, frames)

def test_verify_reports_an_hbm_read_error_as_bad(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()
    second = frames[-1].seq + 2                     # verify's seqs continue after the load
    bad = L.Loader(L.FakeTransport(m, lead=1, rerr_seqs={second}), frames, sha,
                   str(tmp_path / "ck2.json")).run_verify()
    assert [(b[0].addr, b[1]) for b in bad] == [(8192, None)]

def test_verify_waits_for_its_own_range_result_not_a_stale_one(tmp_path):
    """The writer's `last` can move before the CRC unit's result does: the status that
    first shows last == seq may still carry the previous range result with valid=1.
    Verify must match range_seq, or it compares the previous piece's CRC."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()
    bad = L.Loader(L.FakeTransport(m, lead=1, lag_slots=0, stale_range=True), frames, sha,
                   str(tmp_path / "ck2.json")).run_verify()
    assert bad == []
