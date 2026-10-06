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
from jc.jc_model import LoaderModel, DEFAULT_DNA
from jc import coe

def Ld(*a, **k):
    """The Loader with the die identity the models report by default (Task 9b). Tests
    about the identity itself pass dna= explicitly."""
    k.setdefault("dna", DEFAULT_DNA)
    return L.Loader(*a, **k)

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
    st = Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert st["last"] == frames[-1].seq and st["busy"] == 0
    assert_die_holds_the_plan(m, frames)
    assert m.crc_fail == m.seq_err == 0

def test_resync_after_crc_failure_with_pipeline(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=0, fail_seqs={2})
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq
    assert ld.resyncs == 1 and st["crc_fail"] == 1
    assert_die_holds_the_plan(m, frames)

def test_completion_waits_for_status(tmp_path):
    frames, sha = plan(tmp_path, (64,))
    t = L.FakeTransport(LoaderModel(), lead=1, lag_slots=4)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and st["busy"] == 0
    assert ld.resyncs == 0                     # waited for the lagged status, resent nothing

def test_wrong_chain_position_aborts_fast(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, wrong_lead=True)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    with pytest.raises(L.LoadAborted, match="chain"):
        ld.run_load()
    assert t.sent < 64

def test_resume_continues_from_fpga_status(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    t = L.FakeTransport(m, lead=1, drop_after=16)
    with pytest.raises(ConnectionError):
        Ld(t, frames, sha, ck).run_load()
    committed = m.last
    assert committed != 0xFFFFFFFF and committed < frames[-1].seq   # a partial load
    t2 = L.FakeTransport(m, lead=1)
    st = Ld(t2, frames, sha, ck, resume=True).run_load()
    assert st["last"] == frames[-1].seq
    assert t2.first_seq_sent == committed + 1
    assert_die_holds_the_plan(m, frames)

def test_resume_refuses_other_plan(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    t = L.FakeTransport(m, lead=1, drop_after=16)
    with pytest.raises(ConnectionError):
        Ld(t, frames, sha, ck).run_load()
    t2 = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="plan"):
        Ld(t2, frames, "0" * 64, ck, resume=True).run_load()
    assert t2.sent == 0                         # refused before touching the board

def test_verify_reports_a_corrupted_word(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    m.mem[0x40] = b"\xEE" * 32
    bad = Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck2.json")).run_verify()
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
    Ld(L.FakeTransport(m, lead=1, lag_slots=4), frames, sha, str(tmp_path / "ck.json")).run_load()
    bad = Ld(L.FakeTransport(m, lead=1, lag_slots=4), frames, sha,
                   str(tmp_path / "ck2.json")).run_verify()
    assert bad == []

def test_dropped_frame_mid_stream_is_resent(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = Ld(L.FakeTransport(m, lead=1, drop_seqs={3}), frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1 and m.seq_err > 0
    assert_die_holds_the_plan(m, frames)

def test_dropped_last_frame_is_resent_after_the_completion_wait(tmp_path):
    """Nothing after the last frame can raise a counter: completion must notice the
    tail never committed and resend it."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = Ld(L.FakeTransport(m, lead=1, drop_seqs={frames[-1].seq}), frames, sha,
                  str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert_die_holds_the_plan(m, frames)

def test_desync_slot_triggers_resync(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = Ld(L.FakeTransport(m, lead=0, desync_seqs={4}), frames, sha, str(tmp_path / "ck.json"))
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
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1 and t.recovers == 1
    assert_die_holds_the_plan(m, frames)

def test_link_faults_are_bounded(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, fault_sends=set(range(4, 10000)))
    with pytest.raises(L.LoadAborted, match="resyncs"):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert t.recovers <= L.MAX_RESYNCS

def test_repeated_crc_failures_are_bounded(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, fail_seqs={2}, fail_forever=True)
    with pytest.raises(L.LoadAborted, match="resyncs"):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()

def test_fresh_load_refuses_a_die_that_already_holds_frames(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    with pytest.raises(ConnectionError):
        Ld(L.FakeTransport(m, lead=1, drop_after=16), frames, sha, str(tmp_path / "ck.json")).run_load()
    with pytest.raises(L.LoadAborted, match="resume"):
        Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()

def test_resume_without_a_checkpoint_is_refused(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(L.LoadAborted, match="checkpoint"):
        Ld(t, frames, sha, str(tmp_path / "none.json"), resume=True).run_load()
    assert t.sent == 0

def test_checkpoint_records_plan_and_progress(tmp_path):
    frames, sha = plan(tmp_path)
    ck = tmp_path / "ck.json"
    Ld(L.FakeTransport(LoaderModel(), lead=1), frames, sha, str(ck)).run_load()
    d = json.loads(ck.read_text())
    assert d["plan_sha"] == sha and d["last"] == frames[-1].seq

def test_hbm_temperature_trip_aborts(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=0, lag_slots=0, trip_after=4)
    with pytest.raises(L.LoadAborted, match="temperature"):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()

def test_hbm_write_response_error_aborts(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(bad_bresp_addrs={0})
    with pytest.raises(L.LoadAborted, match="BRESP"):
        Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()

def test_loader_refuses_frames_out_of_seq_order(tmp_path):
    frames, sha = plan(tmp_path)
    with pytest.raises(ValueError):
        Ld(L.FakeTransport(LoaderModel(), lead=1), frames[1:], sha, str(tmp_path / "ck.json"))

# ---------------------------------------------------------------- CoeTransport, modelled chain

class ChainSock:
    """A fake BMC socket in front of a modelled two-die JTAG chain (TDI -> device 0 ->
    device 1 -> TDO). It runs an IEEE 1149.1 TAP per TCK, a 12-bit IR per device
    (Test-Logic-Reset loads IDCODE), a 1-bit BYPASS register, and, on the device at
    `loader_pos` while its IR is USER4, the slot-counting receiver of
    rtl/jc_frame_core.vhd: Capture-DR resets the bit counter and loads the status
    shift register; every 16,384 bits is one slot, fed to a LoaderModel; the status
    register reloads at every slot boundary and shifts out LSB first, one bit per TCK
    (TDO = st_sr(0)). The other die has no loader: USER4 on it drives TDO low --
    unless `other` gives it a model too (Task 9b: both dies run the loader, each with
    its own receiver state and its own DNA in its model).

    Every Update-IR value is recorded; any one off the allowlist, a CMD_TDI outside
    Shift-DR, or a CMD_TDI shift under an instruction other than BYPASS/USER4 is
    recorded as a violation. `bad_status_tdi` makes the n-th CMD_TDI reply carry a bad status
    (its bits are still shifted); `flip_seqs` corrupts one bit of that frame once."""
    def __init__(s, model, loader_pos, lag=1, bad_status_tdi=(), flip_seqs=(),
                 start=coe.TEST_LOGIC_RESET, other=None):
        s.m, s.pos, s.lag = model, loader_pos, lag
        s.models = {loader_pos: model}
        if other is not None:
            s.models[1 - loader_pos] = other
        s.bad, s.flip = set(bad_status_tdi), set(flip_seqs)
        s.state = start
        s.ir = [coe.IR_IDCODE, coe.IR_IDCODE]
        s.irsr = [0, 0]
        s.byp = [0, 0]
        s.bitcnt, s.acc, s.st_sr, s.sthist = [0, 0], [0, 0], [0, 0], [[], []]
        s.q, s.ntdi = b"", 0
        s.ir_updates, s.violations = [], []

    def setsockopt(s, *a):
        pass

    def _status(s, d):
        h = s.sthist[d]
        h.append(dict(s.models[d].status()))
        return int.from_bytes(F.pack_status(h[max(0, len(h) - 1 - s.lag)]), "little")

    def _core(s, d, n, x):
        out, i = 0, 0
        while i < n:
            take = min(n - i, F.SLOT_BITS - s.bitcnt[d])
            out |= (s.st_sr[d] & ((1 << take) - 1)) << i
            s.st_sr[d] >>= take
            s.acc[d] |= ((x >> i) & ((1 << take) - 1)) << s.bitcnt[d]
            s.bitcnt[d] += take
            i += take
            if s.bitcnt[d] == F.SLOT_BITS:
                slot = s.acc[d].to_bytes(F.SLOT_BYTES, "little")
                h = F.parse_header(slot)
                if h["magic"] == F.MAGIC_FRAME and h["seq"] in s.flip and (h["nwords"] or h["flags"]):
                    s.flip.discard(h["seq"])
                    b = bytearray(slot); b[100] ^= 1; slot = bytes(b)
                s.models[d].feed(slot)
                s.st_sr[d] = s._status(d)
                s.bitcnt[d], s.acc[d] = 0, 0
        return out

    def _dev(s, d, n, x, tdi_cmd=False):
        if s.ir[d] == coe.IR_USER4:
            return s._core(d, n, x) if d in s.models else 0
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
                if d in s.models and s.ir[d] == coe.IR_USER4:
                    s.bitcnt[d], s.acc[d], s.st_sr[d] = 0, 0, s._status(d)
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
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 0
    assert_die_holds_the_plan(m, frames)
    assert m.desync == 1 and m.crc_fail == 0              # exactly the one filler slot
    assert_chain_clean(sock, client)

def test_coe_transport_resyncs_after_a_crc_failure(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, "B", "AB", 1, flip_seqs={3})
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
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
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
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
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert m.committed == 0 and sock.violations == []

def test_coe_transport_verify_reports_a_corrupted_word(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t, sock, client = chain_transport(m, "B", "AB", 1)
    Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    m.mem[8192 + 0x20] = b"\x11" * 32                         # second word of t1 (64 B at 8192)
    t2, sock2, client2 = chain_transport(m, "B", "AB", 1)
    bad = Ld(t2, frames, sha, str(tmp_path / "ck2.json")).run_verify()
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
    ld = Ld(L.FakeTransport(m, lead=1, **{fault: {frames[-1].seq}}), frames, sha,
                  str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert ld.causes[0].startswith("error counters"), ld.causes
    assert_die_holds_the_plan(m, frames)

def test_verify_reports_an_hbm_read_error_as_bad(tmp_path):
    """Task 9b M2: a piece is retried once with a fresh seq after a read error, so it is
    reported only when the retry reads in error too. Verify's seqs continue after the
    load; with use_plan_seqs off the retry is the very next seq."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()
    second = frames[-1].seq + 2
    ld = Ld(L.FakeTransport(m, lead=1, rerr_seqs={second, second + 1}), frames, sha,
            str(tmp_path / "ck2.json"))
    bad = ld.run_verify()
    assert [(b[0].addr, b[1]) for b in bad] == [(8192, None)]
    assert any(c.startswith("HBM read error on piece 1") for c in ld.causes), ld.causes

def test_verify_waits_for_its_own_range_result_not_a_stale_one(tmp_path):
    """The writer's `last` can move before the CRC unit's result does: the status that
    first shows last == seq may still carry the previous range result with valid=1.
    Verify must match range_seq, or it compares the previous piece's CRC."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()
    bad = Ld(L.FakeTransport(m, lead=1, lag_slots=0, stale_range=True), frames, sha,
                   str(tmp_path / "ck2.json")).run_verify()
    assert bad == []

# ======================================================================
# Task 9 fix round 1 (review 2026-10-05; probes /home/orencollaco/regress_scratch/jc9_rev/)
# ======================================================================
from jc.jc_model import FifoOverflowModel

def partial_load(m, frames, sha, ck, **kw):
    """A load cut short by a dropped link, leaving the die mid data phase."""
    with pytest.raises(ConnectionError):
        Ld(L.FakeTransport(m, lead=1, drop_after=14, **kw), frames, sha, ck).run_load()
    nd = sum(f.kind == "data" for f in frames)
    assert m.last != 0xFFFFFFFF and m.last < nd - 1, m.last
    return nd

def test_c1_verify_refuses_a_partially_loaded_die(tmp_path):
    """verify_then_resume.py: verify used to run its range frames on a partial die,
    whose writer commits them, so `last` jumped into the data seqs and a later
    --resume skipped data frames 4-8 and reported success."""
    frames, sha = plan(tmp_path, (5000, 64, 4096, 20000, 9000))
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    partial_load(m, frames, sha, ck)
    before = m.last
    t = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="finish the load"):
        Ld(t, frames, sha, str(tmp_path / "v.json")).run_verify()
    assert m.last == before and t.state == "closed"
    st = Ld(L.FakeTransport(m, lead=1), frames, sha, ck, resume=True).run_load()
    assert st["last"] == frames[-1].seq
    assert_die_holds_the_plan(m, frames)

def test_resume_after_verify_of_a_complete_die_rechecks_every_piece(tmp_path):
    """After a full load and a verify the die's last is past the plan's final seq.
    --resume must not call that 'another plan': it re-checks every piece by range CRC
    (fresh seqs) and reports the die already complete."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    Ld(L.FakeTransport(m, lead=1), frames, sha, ck).run_load()
    assert Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "v.json")).run_verify() == []
    ld = Ld(L.FakeTransport(m, lead=1), frames, sha, ck, resume=True)
    st = ld.run_load()
    nr = sum(f.kind == "range" for f in frames)
    assert ld.already_complete and len(ld.range_results) == nr
    assert st["last"] == frames[-1].seq + 2 * nr            # load's ranges, verify's, these

def test_load_compares_every_piece_and_reports_the_results(tmp_path):
    frames, sha = plan(tmp_path)
    ld = Ld(L.FakeTransport(LoaderModel(), lead=1), frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    ranges = [f for f in frames if f.kind == "range"]
    assert sorted(ld.range_results) == list(range(len(ranges)))
    assert all(got == want == L.expected_range_crc(ranges[i])
               for i, (got, want) in ld.range_results.items())

def test_i1_resume_onto_another_plans_bytes_aborts_on_range_mismatch(tmp_path):
    """holes.py P2: plan Y partly loaded, bitstream reloaded, plan X (same layout,
    different bytes) partly loaded, then Y resumed with Y's checkpoint. The die's last
    says Y is far along, but the bytes below it are X's: the range phase must catch it."""
    dy, dx = tmp_path / "y", tmp_path / "x"
    dy.mkdir(); dx.mkdir()
    fy, shy = L.plan_frames(make_manifest(dy, [5000, 64, 4096, 20000]))
    mpx = make_manifest(dx, [5000, 64, 4096, 20000])
    mani = json.load(open(mpx))
    for e in mani["files"]:
        p = dx / e["file"]
        b = bytes(x ^ 0x5A for x in p.read_bytes()); p.write_bytes(b)
        e["blake2b_128"] = hashlib.blake2b(b, digest_size=16).hexdigest()
    json.dump(mani, open(mpx, "w"))
    fx, shx = L.plan_frames(mpx)
    ck = str(tmp_path / "ckY.json")
    partial_load(LoaderModel(), fy, shy, ck)
    m2 = LoaderModel()
    with pytest.raises(ConnectionError):
        Ld(L.FakeTransport(m2, lead=1, drop_after=20), fx, shx, str(tmp_path / "ckX.json")).run_load()
    t = L.FakeTransport(m2, lead=1)
    with pytest.raises(L.LoadAborted, match="range CRC") as e:
        Ld(t, fy, shy, ck, resume=True).run_load()
    assert "0x0" in str(e.value)                              # names the first piece
    assert t.state == "closed"

def test_i3_range_phase_survives_crc_busy_time_and_a_finite_fifo(tmp_path):
    """The review's crcqueue.py: on the 9B manifest the CRC unit needs longer than the
    range frames take to send, so a pipelined range phase backs range frames up in the
    128+2-entry FIFO until it overflows. Here each 64-byte piece's CRC takes 20 slots
    (FifoOverflowModel with CRC timing): the serialised range phase must load and check
    all 100 pieces with no overflow and no resync."""
    frames, sha = plan(tmp_path, [64] * 100)
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=20 / 64)
    t = L.FakeTransport(m, lead=1, lag_slots=1)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert not m.ovf and m.crc_fail == 0 and ld.resyncs == 0
    assert st["last"] == frames[-1].seq and len(ld.range_results) == 100
    assert_die_holds_the_plan(m, frames)

def test_i3_the_timed_model_overflows_on_a_pipelined_range_burst():
    """Teeth for the test above: the same model, fed range frames back to back (what
    the old run_load did), overflows."""
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=20 / 64)
    for k in range(70):
        m.tick(1)
        m.feed_slot(F.build_slot(k, 0, b"\1" * 32))
    for k in range(70, 170):
        m.tick(1)
        m.feed_slot(F.range_crc_slot(k, 0, 64))
    assert m.ovf

def test_i3_timed_model_reports_busy_until_the_crc_is_done():
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=10 / 64)
    m.feed_slot(F.build_slot(0, 0, b"\7" * 64))
    m.feed_slot(F.range_crc_slot(1, 0, 64))
    st = m.loader_status()
    assert st["last"] == 1 and st["range_seq"] == 1 and st["busy"] == 1 and st["range_valid"] == 0
    m.tick(10)
    st = m.loader_status()
    assert st["busy"] == 0 and st["range_valid"] == 1
    assert st["range_crc"] == zlib.crc32(b"\7" * 64) & 0xFFFFFFFF

def test_i2_resume_onto_a_die_with_a_bresp_error_aborts(tmp_path):
    """holes.py P1: a BRESP error committed just before the link dropped (the lagged
    status never showed it), then --resume: the new run's baseline used to absorb it.
    A fresh configuration starts at 0, so any nonzero count at open aborts."""
    frames, sha = plan(tmp_path, (5000, 64, 4096, 20000))
    ck = str(tmp_path / "ck.json")
    for da in range(8, 40):
        m = LoaderModel(bad_bresp_addrs={frames[3].addr})
        try:
            Ld(L.FakeTransport(m, lead=1, lag_slots=4, drop_after=da), frames, sha, ck).run_load()
        except ConnectionError:
            if m.bresp_err and m.last < frames[-1].seq:
                break
        except L.LoadAborted:
            continue
    else:
        pytest.fail("no drop point left an unseen BRESP error")
    t = L.FakeTransport(m, lead=1, lag_slots=4)
    with pytest.raises(L.LoadAborted, match="BRESP"):
        Ld(t, frames, sha, ck, resume=True).run_load()
    assert t.state == "closed"

def test_i2_verify_refuses_a_die_with_a_bresp_error(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()
    m.bresp_err = 1
    with pytest.raises(L.LoadAborted, match="BRESP"):
        Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "v.json")).run_verify()

@pytest.mark.parametrize("content", ["{not json", "[1,2]", "null", '{"plan_sha": null}', '{"x": 1}'])
def test_corrupt_or_foreign_checkpoint_is_a_clean_refusal(tmp_path, content):
    frames, sha = plan(tmp_path, (64,))
    p = tmp_path / "c.json"
    p.write_text(content)
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(L.LoadAborted, match="delete it"):
        Ld(t, frames, sha, str(p), resume=True).run_load()
    assert t.sent == 0

def test_checkpoint_is_fsynced_before_it_replaces_the_old_one(tmp_path, monkeypatch):
    events = []
    real_fsync, real_replace = os.fsync, os.replace
    monkeypatch.setattr(L.os, "fsync", lambda fd: (events.append("fsync"), real_fsync(fd))[1])
    monkeypatch.setattr(L.os, "replace", lambda a, b: (events.append("replace"), real_replace(a, b))[1])
    frames, sha = plan(tmp_path, (64,))
    Ld(L.FakeTransport(LoaderModel(), lead=1), frames, sha, str(tmp_path / "ck.json")).run_load()
    assert events and events[0] == "fsync"
    assert all(events[i] == "fsync" for i in range(0, len(events), 2))
    assert all(events[i] == "replace" for i in range(1, len(events), 2))

@pytest.mark.parametrize("exc", [TimeoutError("timed out"), ConnectionResetError("reset")])
def test_cli_turns_socket_errors_into_the_abort_sentinel(tmp_path, monkeypatch, capsys, exc):
    mp = make_manifest(tmp_path, [64])
    def boom(*a, **k):
        raise exc
    monkeypatch.setattr(L, "CoeTransport", boom)
    dies = tmp_path / "dies.json"
    dies.write_text(json.dumps({"A": L.dna_hex(DEFAULT_DNA)}))
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", str(dies), "--ckpt", str(tmp_path / "ck.json")])
    assert rc == 2
    assert re_match_line(capsys.readouterr().out, r"^JCLOAD_ABORT ")

def re_match_line(text, pat):
    import re
    return re.search(pat, text, re.M) is not None

def test_an_abort_closes_the_scan_on_the_real_client(tmp_path):
    """Wrong --chain aborts mid-scan: the transport must drain and leave Shift-DR
    (shadow and modelled real TAP both back at Run-Test/Idle), not strand it."""
    frames, sha = plan(tmp_path)
    t, sock, client = chain_transport(LoaderModel(), "A", "BA", 0)
    with pytest.raises(L.LoadAborted):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert client.outstanding == [] and client.tap == coe.RUN_TEST_IDLE == sock.state

def test_an_abort_closes_the_fake_scan(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(bad_bresp_addrs={0}), lead=1)
    with pytest.raises(L.LoadAborted, match="BRESP"):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert t.state == "closed" and t.abort_closes == 1

def test_range_wait_scales_with_the_piece_size(tmp_path):
    """A big piece's CRC can take longer than MAX_POLLS polls (9B card 0: up to 2.28 MB
    per piece). The wait allows MAX_POLLS + the piece at RANGE_EXPECT_BPS (Task 9b M3:
    in TIME, from the transport's TCK rate); here a 1 MiB piece's CRC takes 40 slots,
    more than MAX_POLLS, and must not be called lost."""
    n = 1 << 20
    frames, sha = plan(tmp_path, (n,))
    assert 40 > L.MAX_POLLS and 40 < L.range_polls(n, L.RANGE_EXPECT_BPS, 27_000_000)
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=40 / n)
    ld = Ld(L.FakeTransport(m, lead=1, lag_slots=1), frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    assert ld.resyncs == 0 and len(ld.range_results) == 1

def test_dropped_last_data_frame_is_resent_after_the_data_phase_wait(tmp_path):
    """The data phase's own tail: nothing after the last DATA frame raises a counter
    before the range phase, so the data-phase wait must notice and resend it."""
    frames, sha = plan(tmp_path)
    nd = sum(f.kind == "data" for f in frames)
    m = LoaderModel()
    ld = Ld(L.FakeTransport(m, lead=1, drop_seqs={nd - 1}), frames, sha,
                  str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 1
    assert ld.causes == ["seq %d never committed" % (nd - 1)]
    assert_die_holds_the_plan(m, frames)

def test_an_abort_with_replies_in_flight_drains_and_leaves_shift_dr(tmp_path):
    """A BRESP abort lands while 3 pipelined CMD_TDI replies are unread: abort_close
    must drain them, or exit_dr_to_idle is refused and the TAP is left in Shift-DR."""
    frames, sha = plan(tmp_path)
    t, sock, client = chain_transport(LoaderModel(bad_bresp_addrs={0}), "A", "AB", 0)
    with pytest.raises(L.LoadAborted, match="BRESP"):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert client.outstanding == [] and client.tap == coe.RUN_TEST_IDLE == sock.state
    assert sock.violations == []

# ======================================================================
# Task 9b: DNA_PORTE2 die identity in the 384-bit status word, the die record (--dies)
# and `identify`. Every DNA below is MADE UP (distinct halves, not palindromes); no DNA
# read from real hardware is ever committed.
# ======================================================================
DNA_A = 0x13579BDF2468ACE0F1E2D3C4
DNA_B = 0xF00DCAFE12345678DEADBEA7

def dies_file(tmp_path, rec, name="dies.json"):
    p = tmp_path / name
    p.write_text(json.dumps({k: L.dna_hex(v) for k, v in rec.items()}))
    return str(p)

def assert_masked(text, *dnas):
    """Fix round 1, M6: load/verify name each DNA masked, never in full."""
    for v in dnas:
        assert L.dna_mask(v) in text, (L.dna_mask(v), text)
        assert L.dna_hex(v) not in text and L.dna_hex(v).upper() not in text, text

def count_range_sends(t):
    """Wrap t.send to count range-CRC frames put on the wire."""
    n = [0]
    real = t.send
    def send(slot):
        if F.parse_header(slot)["flags"] & F.FLAG_RANGE_CRC:
            n[0] += 1
        return real(slot)
    t.send = send
    return n

def test_a_die_with_another_dna_aborts_before_any_data_frame(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(dna=DNA_A)
    t = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="check --chain and --die") as e:
        Ld(t, frames, sha, str(tmp_path / "ck.json"), dna=DNA_B).run_load()
    assert_masked(str(e.value), DNA_A, DNA_B)
    assert t.first_seq_sent is None and m.committed == 0 and t.state == "closed"

def test_two_loaders_wrong_chain_is_caught_by_the_dna(tmp_path):
    """The scenario Task 9's review found: BOTH dies run the loader, the real chain is AB
    (die A nearest TDI). (die=A, chain=AB) and (die=B, chain=BA) put identical traffic
    on the wire, so before Task 9b `--die B --chain BA` loaded die A undetected. Now the
    DNA die A reports does not match the record's B and the load aborts with nothing
    written to either die."""
    frames, sha = plan(tmp_path)
    mA, mB = LoaderModel(dna=DNA_A), LoaderModel(dna=DNA_B)
    rec = {"A": DNA_A, "B": DNA_B}
    tA, sockA, _ = chain_transport(LoaderModel(), "A", "AB", 0)
    tBx, sockBx, _ = chain_transport(LoaderModel(), "B", "BA", 0)
    assert (tA.ops, tA.lead, tA.status_offset) == (tBx.ops, tBx.lead, tBx.status_offset)

    # the mistake: die B, chain BA -> USER4 on position 0, which is really die A
    t, sock, client = chain_transport(mA, "B", "BA", 0, other=mB)
    with pytest.raises(L.LoadAborted, match="check --chain and --die") as e:
        Ld(t, frames, sha, str(tmp_path / "ck.json"), dna=rec["B"]).run_load()
    assert_masked(str(e.value), DNA_A, DNA_B)
    assert mA.committed == 0 and mB.committed == 0
    assert_chain_clean(sock, client)

    # the right setting loads die B and leaves die A alone
    t, sock, client = chain_transport(mB, "B", "AB", 1, other=mA)
    st = Ld(t, frames, sha, str(tmp_path / "ck2.json"), dna=rec["B"]).run_load()
    assert st["last"] == frames[-1].seq and st["dna"] == DNA_B
    assert_die_holds_the_plan(mB, frames)
    assert mA.committed == 0 and mA.mem == {}
    assert_chain_clean(sock, client)

def test_a_late_dna_valid_is_waited_for(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(dna=DNA_A)
    t = L.FakeTransport(m, lead=1, dna_valid_after=20)
    st = Ld(t, frames, sha, str(tmp_path / "ck.json"), dna=DNA_A).run_load()
    assert st["last"] == frames[-1].seq and ld_ok(st)
    assert_die_holds_the_plan(m, frames)

def ld_ok(st):
    return st["dna_valid"] == 1 and st["dna"] == DNA_A

def test_dna_valid_never_set_aborts_after_bounded_polls(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(dna=0, dna_valid=0)
    t = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="dna_valid"):
        Ld(t, frames, sha, str(tmp_path / "ck.json"), dna=DNA_A).run_load()
    assert t.first_seq_sent is None and m.committed == 0
    assert t.sent <= 2 * L.MAX_POLLS and t.state == "closed"

class SwappingModel(LoaderModel):
    """A die whose identity changes after `after` real frames (stands in for a die that
    was reconfigured or a chain that changed under the run)."""
    def __init__(s, after, new_dna, new_valid, **kw):
        super().__init__(**kw)
        s.after, s.new = after, (new_dna, new_valid)
    def feed(s, slot):
        super().feed(slot)
        if s.committed >= s.after:
            s.dna, s.dna_valid = s.new

@pytest.mark.parametrize("new,match", [((DNA_B, 1), "changed under the run"),
                                       ((0, 0), "went invalid")])
def test_a_dna_change_mid_run_aborts(tmp_path, new, match):
    frames, sha = plan(tmp_path)
    m = SwappingModel(5, *new, dna=DNA_A)
    with pytest.raises(L.LoadAborted, match=match):
        Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json"), dna=DNA_A).run_load()
    assert m.last < frames[-1].seq

def test_checkpoint_records_the_dna(tmp_path):
    frames, sha = plan(tmp_path)
    ck = tmp_path / "ck.json"
    Ld(L.FakeTransport(LoaderModel(dna=DNA_A), lead=1), frames, sha, str(ck), dna=DNA_A).run_load()
    assert json.loads(ck.read_text())["dna"] == L.dna_hex(DNA_A)

@pytest.mark.parametrize("ck_dna", [L.dna_hex(DNA_B), None])
def test_resume_refuses_a_checkpoint_for_another_dna(tmp_path, ck_dna):
    """A checkpoint written for another die's DNA (or by a loader that recorded none) is
    refused before the board is touched."""
    frames, sha = plan(tmp_path)
    m = LoaderModel(dna=DNA_A)
    ck = tmp_path / "ck.json"
    with pytest.raises(ConnectionError):
        Ld(L.FakeTransport(m, lead=1, drop_after=16), frames, sha, str(ck), dna=DNA_A).run_load()
    d = json.loads(ck.read_text())
    assert d["dna"] == L.dna_hex(DNA_A)
    if ck_dna is None:
        del d["dna"]
    else:
        d["dna"] = ck_dna
    ck.write_text(json.dumps(d))
    t2 = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="DNA"):
        Ld(t2, frames, sha, str(ck), dna=DNA_A, resume=True).run_load()
    assert t2.sent == 0 and t2.opens == 0

def test_resume_with_the_same_dna_still_works(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(dna=DNA_A)
    ck = str(tmp_path / "ck.json")
    with pytest.raises(ConnectionError):
        Ld(L.FakeTransport(m, lead=1, drop_after=16), frames, sha, ck, dna=DNA_A).run_load()
    st = Ld(L.FakeTransport(m, lead=1), frames, sha, ck, dna=DNA_A, resume=True).run_load()
    assert st["last"] == frames[-1].seq

# ---------------------------------------------------------------- die record

@pytest.mark.parametrize("content,match", [
    ('{"A": "0123"}', "24 hex digits"),
    ('{"C": "%s"}' % L.dna_hex(DNA_A), "keys"),
    ('["%s"]' % L.dna_hex(DNA_A), "keys"),
    ('{not json', "unreadable"),
    ('{"A": "%s", "B": "%s"}' % (L.dna_hex(DNA_A), L.dna_hex(DNA_A)), "same DNA"),
    ('{"A": 5}', "24 hex digits")])
def test_a_bad_die_record_is_refused(tmp_path, content, match):
    p = tmp_path / "dies.json"
    p.write_text(content)
    with pytest.raises(L.LoadAborted, match=match):
        L.read_dies(str(p))

def test_a_die_missing_from_the_record_says_run_identify(tmp_path):
    p = dies_file(tmp_path, {"A": DNA_A})
    assert L.dna_for(p, "A") == DNA_A
    with pytest.raises(L.LoadAborted, match="identify"):
        L.dna_for(p, "B")
    with pytest.raises(L.LoadAborted, match="identify"):
        L.dna_for(str(tmp_path / "absent.json"), "A")

def test_the_die_record_may_not_live_in_the_repo():
    inside = os.path.join(L.REPO, "tools", "jc", "dies_should_never_exist.json")
    assert not os.path.exists(inside)
    with pytest.raises(L.LoadAborted, match="outside"):
        L.read_dies(inside)
    with pytest.raises(L.LoadAborted, match="outside"):
        L.write_dies(inside, {"A": DNA_A})
    assert not os.path.exists(inside)

def test_cli_load_requires_dies(tmp_path):
    mp = make_manifest(tmp_path, [64])
    with pytest.raises(SystemExit) as e:
        L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB"])
    assert e.value.code == 2

def test_cli_load_with_the_die_missing_from_the_record_aborts_before_the_board(tmp_path, monkeypatch, capsys):
    mp = make_manifest(tmp_path, [64])
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: pytest.fail("touched the board"))
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "B", "--chain", "AB",
                 "--dies", dies_file(tmp_path, {"A": DNA_A}), "--ckpt", str(tmp_path / "ck.json")])
    out = capsys.readouterr().out
    assert rc == 2 and re_match_line(out, r"^JCLOAD_ABORT .*identify")

def test_cli_load_passes_the_record_dna_to_the_loader(tmp_path, monkeypatch, capsys):
    mp = make_manifest(tmp_path, [64])
    m = LoaderModel(dna=DNA_B)
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(m, lead=1))
    dies = dies_file(tmp_path, {"A": DNA_A, "B": DNA_B})
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck.json")])
    out = capsys.readouterr().out
    assert rc == 2 and re_match_line(out, r"^JCLOAD_ABORT die identity mismatch")
    assert dies in out and m.committed == 0
    assert_masked(out, DNA_A, DNA_B)

# ---------------------------------------------------------------- identify

def test_identify_writes_refuses_overwrite_and_honours_force(tmp_path):
    p = str(tmp_path / "sub" / "dies.json")                # parent created
    assert L.identify(L.FakeTransport(LoaderModel(dna=DNA_A), lead=1), "A", p) == (DNA_A, "added")
    assert json.loads(open(p).read()) == {"A": L.dna_hex(DNA_A)}
    assert L.identify(L.FakeTransport(LoaderModel(dna=DNA_A), lead=1), "A", p) == (DNA_A, "unchanged")
    other = 0x0F1E2D3C4B5A69788796A5B4
    with pytest.raises(L.LoadAborted, match="--force"):
        L.identify(L.FakeTransport(LoaderModel(dna=other), lead=1), "A", p)
    assert json.loads(open(p).read()) == {"A": L.dna_hex(DNA_A)}
    assert L.identify(L.FakeTransport(LoaderModel(dna=other), lead=1), "A", p, force=True) == (other, "replaced")
    assert json.loads(open(p).read()) == {"A": L.dna_hex(other)}
    assert L.identify(L.FakeTransport(LoaderModel(dna=DNA_B), lead=1), "B", p) == (DNA_B, "added")
    assert L.read_dies(p) == {"A": other, "B": DNA_B}

def test_identify_refuses_the_other_dies_dna_even_with_force(tmp_path):
    p = dies_file(tmp_path, {"A": DNA_A})
    for force in (False, True):
        with pytest.raises(L.LoadAborted, match="already records as die A"):
            L.identify(L.FakeTransport(LoaderModel(dna=DNA_A), lead=1), "B", p, force=force)
    assert L.read_dies(p) == {"A": DNA_A}

def test_identify_refuses_a_bad_record_before_the_board(tmp_path):
    p = tmp_path / "dies.json"
    p.write_text("{broken")
    t = L.FakeTransport(LoaderModel(dna=DNA_A), lead=1)
    with pytest.raises(L.LoadAborted, match="unreadable"):
        L.identify(t, "A", str(p))
    assert t.opens == 0

def test_identify_waits_for_dna_valid_and_aborts_if_never(tmp_path):
    p = str(tmp_path / "dies.json")
    assert L.identify(L.FakeTransport(LoaderModel(dna=DNA_A), lead=1, dna_valid_after=20), "A", p)[0] == DNA_A
    t = L.FakeTransport(LoaderModel(dna=0, dna_valid=0), lead=1)
    with pytest.raises(L.LoadAborted, match="dna_valid"):
        L.identify(t, "B", p)
    assert L.read_dies(p) == {"A": DNA_A} and t.state == "closed"

def test_identify_over_a_modelled_chain_reads_the_die_at_that_position(tmp_path):
    """Both dies run the loader, the real chain is AB. identify A with chain AB reads A;
    then identify B with the WRONG chain BA reads A again, which the record already
    holds for A: refused. With the right chain it records B."""
    p = str(tmp_path / "dies.json")
    mA, mB = LoaderModel(dna=DNA_A), LoaderModel(dna=DNA_B)
    t, sock, client = chain_transport(mA, "A", "AB", 0, other=mB)
    assert L.identify(t, "A", p) == (DNA_A, "added")
    assert_chain_clean(sock, client)
    t, sock, client = chain_transport(mA, "B", "BA", 0, other=mB)
    with pytest.raises(L.LoadAborted, match="already records as die A"):
        L.identify(t, "B", p)
    t, sock, client = chain_transport(mB, "B", "AB", 1, other=mA)
    assert L.identify(t, "B", p) == (DNA_B, "added")
    assert_chain_clean(sock, client)
    assert mA.committed == mB.committed == 0
    assert L.read_dies(p) == {"A": DNA_A, "B": DNA_B}

def test_cli_identify(tmp_path, monkeypatch, capsys):
    p = str(tmp_path / "dies.json")
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(LoaderModel(dna=DNA_B), lead=1))
    rc = L.main(["identify", "--bmc", "192.0.2.1", "--chain", "BA", "--die", "B", "--dies", p])
    out = capsys.readouterr().out
    assert rc == 0 and re_match_line(out, r"^JCIDENTIFY_DONE die=B chain=BA dna=%s added" % L.dna_hex(DNA_B))
    assert L.read_dies(p) == {"B": DNA_B}
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(LoaderModel(dna=DNA_A), lead=1))
    rc = L.main(["identify", "--bmc", "192.0.2.1", "--chain", "BA", "--die", "B", "--dies", p])
    assert rc == 2 and re_match_line(capsys.readouterr().out, r"^JCIDENTIFY_ABORT .*--force")

def test_identify_help_states_the_cross_check_procedure(capsys):
    with pytest.raises(SystemExit):
        L.main(["identify", "--help"])
    out = " ".join(capsys.readouterr().out.split())
    for phrase in ("CANNOT tell AB from BA", "ONCE, at bring-up", "Vivado hardware manager",
                   "outside the repo"):
        assert phrase.lower() in out.lower(), phrase

# ---------------------------------------------------------------- Task 9 minors M1-M3

TPB_RTL = 1500e-9 / 512 / 0.607e-3          # slots per byte at the RTL-derived CRC rate

@pytest.mark.parametrize("slow", [10, 100])
def test_m1_a_slow_crc_on_a_1mb_piece_completes_without_a_rerequest(tmp_path, slow):
    """The reviewer's rangeattack.py: a CRC 10x slower than the RTL-derived rate on a
    1 MB piece used to time out, reopen and re-request until MAX_RESYNCS. The wait must
    keep polling while the die shows the frame committed and the CRC unit busy."""
    frames, sha = plan(tmp_path, (1 << 20, 64))
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=TPB_RTL * slow)
    t = L.FakeTransport(m, lead=1, lag_slots=2)
    nr = count_range_sends(t)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq and ld.resyncs == 0
    assert nr[0] == 2 and len(ld.range_results) == 2

def test_m1_a_crc_that_never_finishes_gives_up_bounded(tmp_path):
    frames, sha = plan(tmp_path, (64,))
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=1e9)
    t = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted):
        Ld(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert t.sent < 2000

def test_m1_a_reopen_accepts_the_result_its_settled_status_carries(tmp_path):
    """A bad CoE reply on the poll right after a range frame: recover, reopen, and the
    settled status already carries that frame's result -- accept it, do not send the
    range frame again (that would queue a second CRC of the same piece)."""
    frames, sha = plan(tmp_path, (64,))
    nd = sum(f.kind == "data" for f in frames)
    m = LoaderModel()
    probe = L.FakeTransport(LoaderModel(), lead=1)
    nsend = count_range_sends(probe)
    sends_before_range = []
    real = probe.send
    def send(slot):
        if F.parse_header(slot)["flags"] & F.FLAG_RANGE_CRC and not sends_before_range:
            sends_before_range.append(probe.sent)
        return real(slot)
    probe.send = send
    Ld(probe, frames, sha, str(tmp_path / "p.json")).run_load()
    k = sends_before_range[0] + 1                       # the first poll after the range frame
    t = L.FakeTransport(m, lead=1, fault_sends={k})
    nr = count_range_sends(t)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert t.recovers == 1 and ld.resyncs == 1
    assert nr[0] == 1 and len(ld.range_results) == 1 and st["last"] == frames[-1].seq

def test_m2_one_read_error_is_retried_and_the_load_completes(tmp_path):
    frames, sha = plan(tmp_path)
    first = next(f.seq for f in frames if f.kind == "range")
    t = L.FakeTransport(LoaderModel(), lead=1, rerr_seqs={first + 1})
    nr = count_range_sends(t)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    nrange = sum(f.kind == "range" for f in frames)
    assert nr[0] == nrange + 1 and ld.resyncs == 0
    assert all(g == w for g, w in ld.range_results.values())
    assert ld.causes == ["HBM read error on piece 1 (seq %d): retried once" % (first + 1)]

def test_m2_a_repeated_read_error_aborts_saying_resume_rechecks(tmp_path):
    frames, sha = plan(tmp_path)
    first, final = next(f.seq for f in frames if f.kind == "range"), frames[-1].seq
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    with pytest.raises(L.LoadAborted, match="--resume.*no reload needed") as e:
        Ld(L.FakeTransport(m, lead=1, rerr_seqs={first + 1, final + 1}), frames, sha, ck).run_load()
    assert "RERR" in str(e.value)
    ld = Ld(L.FakeTransport(m, lead=1), frames, sha, ck, resume=True)
    ld.run_load()                                           # the advice works
    assert ld.already_complete and all(g == w for g, w in ld.range_results.values())

def test_m3_the_range_wait_is_time_based():
    """At a slower TCK each poll slot takes longer, so the same CRC time is fewer polls."""
    n = 1 << 20
    fast, slow = L.range_polls(n, L.RANGE_EXPECT_BPS, 27_000_000), L.range_polls(n, L.RANGE_EXPECT_BPS, 2_700_000)
    assert fast > slow >= L.MAX_POLLS
    # 1 MiB at 100 MB/s is 10.5 ms; a 27 MHz slot is 0.607 ms: 18 polls beyond MAX_POLLS
    assert fast == L.MAX_POLLS + 18

def test_m1_a_reopen_while_a_long_crc_runs_waits_for_it_to_settle(tmp_path):
    """A bad CoE reply right after the range frame of a 1 MiB piece whose CRC runs ~500
    slots (100x slower than the RTL-derived rate): the reopen's settle sees busy = 1 for
    far longer than MAX_POLLS and must keep polling while the die reports busy, then take
    the result its settled status carries."""
    frames, sha = plan(tmp_path, (1 << 20,))
    nd = sum(f.kind == "data" for f in frames)
    probe = L.FakeTransport(FifoOverflowModel(depth=128, crc_ticks_per_byte=TPB_RTL * 100), lead=1)
    at = []
    real = probe.send
    def send(slot):
        if F.parse_header(slot)["flags"] & F.FLAG_RANGE_CRC and not at:
            at.append(probe.sent)
        return real(slot)
    probe.send = send
    Ld(probe, frames, sha, str(tmp_path / "p.json")).run_load()
    m = FifoOverflowModel(depth=128, crc_ticks_per_byte=TPB_RTL * 100)
    t = L.FakeTransport(m, lead=1, fault_sends={at[0] + 1})
    nr = count_range_sends(t)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert t.recovers == 1 and nr[0] == 1 and len(ld.range_results) == 1
    assert st["last"] == frames[-1].seq and all(g == w for g, w in ld.range_results.values())


# ======================================================================
# Task 9b fix round 1 (review 2026-10-05)
# ======================================================================

def test_dna_mask():
    assert L.dna_mask(DEFAULT_DNA) == "0123...ffee"
    assert L.dna_mask(0) == "0000...0000"

def test_m6_a_foreign_checkpoint_names_the_dnas_masked(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel(dna=DNA_A)
    ck = tmp_path / "ck.json"
    with pytest.raises(ConnectionError):
        Ld(L.FakeTransport(m, lead=1, drop_after=16), frames, sha, str(ck), dna=DNA_A).run_load()
    d = json.loads(ck.read_text()); d["dna"] = L.dna_hex(DNA_B); ck.write_text(json.dumps(d))
    with pytest.raises(L.LoadAborted, match="DNA") as e:
        Ld(L.FakeTransport(m, lead=1), frames, sha, str(ck), dna=DNA_A, resume=True).run_load()
    assert_masked(str(e.value), DNA_A, DNA_B)

def test_m6_only_identify_prints_the_full_dna(tmp_path, monkeypatch, capsys):
    mp = make_manifest(tmp_path, [64])
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    m = LoaderModel()                                   # one die for both commands
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(m, lead=1))
    for cmd in ("load", "verify"):
        rc = L.main([cmd, mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                     "--dies", dies, "--ckpt", str(tmp_path / "ck.json")])
        assert rc == 0
    out = capsys.readouterr().out
    assert L.dna_hex(DEFAULT_DNA) not in out
    rc = L.main(["identify", "--bmc", "192.0.2.1", "--chain", "AB", "--die", "A",
                 "--dies", dies])
    assert rc == 0 and L.dna_hex(DEFAULT_DNA) in capsys.readouterr().out

@pytest.mark.parametrize("content", ['{"A": "%s\\n"}' % L.dna_hex(DNA_A),
                                     '{"A": "%s "}' % L.dna_hex(DNA_A)])
def test_m3_a_dna_with_trailing_characters_is_refused(tmp_path, content):
    p = tmp_path / "dies.json"
    p.write_text(content)
    with pytest.raises(L.LoadAborted, match="24 hex digits"):
        L.read_dies(str(p))

def test_m3_duplicate_keys_in_the_die_record_are_refused(tmp_path):
    """json.load keeps the LAST of two equal keys silently; the record must refuse."""
    p = tmp_path / "dies.json"
    p.write_text('{"A": "%s", "A": "%s"}' % (L.dna_hex(DNA_A), L.dna_hex(DNA_B)))
    with pytest.raises(L.LoadAborted, match="duplicate"):
        L.read_dies(str(p))

def _checkout_of_this_file():
    d = os.path.dirname(os.path.realpath(__file__))
    while not os.path.lexists(os.path.join(d, ".git")):
        if os.path.dirname(d) == d:
            pytest.skip("this test file is not inside a git checkout")
        d = os.path.dirname(d)
    return d

def test_i1_a_relative_path_at_the_repo_root_is_refused(tmp_path, monkeypatch):
    root = _checkout_of_this_file()
    monkeypatch.chdir(root)
    assert not os.path.exists("ck_i1_should_never_exist.json")
    with pytest.raises(L.LoadAborted, match="git checkout"):
        L.read_dies("dies_i1_should_never_exist.json")
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(L.LoadAborted, match="git checkout"):
        Ld(t, frames, sha, "ck_i1_should_never_exist.json").run_load()
    assert t.opens == 0 and not os.path.exists("ck_i1_should_never_exist.json")

def test_i1_another_worktree_is_refused(tmp_path):
    """A linked worktree has a `.git` FILE, not a directory; and it is not the checkout
    coe_load.py runs from (the old guard compared against REPO only)."""
    wt = tmp_path / "wt27"
    (wt / "sub").mkdir(parents=True)
    (wt / ".git").write_text("gitdir: /nowhere/.git/worktrees/wt27\n")
    p = str(wt / "sub" / "dies.json")
    with pytest.raises(L.LoadAborted, match="git checkout"):
        L.write_dies(p, {"A": DNA_A})
    assert not os.path.exists(p)
    with pytest.raises(L.LoadAborted, match="git checkout"):
        L.read_dies(p, must_exist=False)
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(L.LoadAborted, match="git checkout"):
        Ld(t, frames, sha, str(wt / "ck.json")).run_load()
    assert t.opens == 0 and not (wt / "ck.json").exists()

def test_i1_a_symlinked_directory_into_a_checkout_is_refused(tmp_path):
    """tmp_path/link -> <checkout>/tools: the textual path has no .git above it, the
    resolved one does. An abspath-based guard would accept it."""
    root = _checkout_of_this_file()
    link = tmp_path / "link"
    os.symlink(os.path.join(root, "tools"), str(link))
    with pytest.raises(L.LoadAborted, match="git checkout"):
        L.read_dies(str(link / "dies_i1_should_never_exist.json"))
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(L.LoadAborted, match="git checkout"):
        Ld(t, frames, sha, str(link / "ck_i1_should_never_exist.json")).run_load()
    assert t.opens == 0
    assert not os.path.exists(os.path.join(root, "tools", "ck_i1_should_never_exist.json"))

def test_i1_the_default_checkpoint_path_is_accepted():
    p = L.default_ckpt("0" * 64, "A")
    assert p.startswith(L.CKPT_DIR + os.sep)
    L._outside_repo(p, "the checkpoint")                 # must not raise

def test_i1_cli_refuses_a_ckpt_in_a_checkout_before_the_board(tmp_path, monkeypatch, capsys):
    root = _checkout_of_this_file()
    mp = make_manifest(tmp_path, [64])
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: pytest.fail("touched the board"))
    ck = os.path.join(root, "ck_i1_should_never_exist.json")
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies_file(tmp_path, {"A": DEFAULT_DNA}), "--ckpt", ck])
    assert rc == 2 and re_match_line(capsys.readouterr().out, r"^JCLOAD_ABORT the checkpoint .*git checkout")
    assert not os.path.exists(ck)

# ======================================================================
# Final review (fix round 3, 2026-10-05): items 1-6
# ======================================================================

# ---------------------------------------------------------------- item 1: --hz

def test_cli_hz_default_reaches_the_transport(tmp_path, monkeypatch):
    mp = make_manifest(tmp_path, [64])
    seen = {}
    def fake_transport(ip, die, chain, hz=None, client=None):
        seen["hz"] = hz
        return L.FakeTransport(LoaderModel(), lead=1)
    monkeypatch.setattr(L, "CoeTransport", fake_transport)
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck.json")])
    assert rc == 0 and seen["hz"] == 27_000_000

def test_cli_hz_override_reaches_the_transport(tmp_path, monkeypatch):
    mp = make_manifest(tmp_path, [64])
    seen = {}
    def fake_transport(ip, die, chain, hz=None, client=None):
        seen["hz"] = hz
        return L.FakeTransport(LoaderModel(), lead=1)
    monkeypatch.setattr(L, "CoeTransport", fake_transport)
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck.json"), "--hz", "1000000"])
    assert rc == 0 and seen["hz"] == 1_000_000

def test_cli_hz_also_reaches_identify(tmp_path, monkeypatch):
    seen = {}
    def fake_transport(ip, die, chain, hz=None, client=None):
        seen["hz"] = hz
        return L.FakeTransport(LoaderModel(dna=DNA_A), lead=1)
    monkeypatch.setattr(L, "CoeTransport", fake_transport)
    rc = L.main(["identify", "--bmc", "192.0.2.1", "--chain", "AB", "--die", "A",
                 "--dies", str(tmp_path / "dies.json"), "--hz", "5000000"])
    assert rc == 0 and seen["hz"] == 5_000_000

def test_cli_hz_27000000_is_accepted_exactly(tmp_path, monkeypatch):
    mp = make_manifest(tmp_path, [64])
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(LoaderModel(), lead=1))
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck.json"), "--hz", "27000000"])
    assert rc == 0

@pytest.mark.parametrize("hz", ["27000001", "100000000"])
def test_cli_hz_refuses_above_27mhz(tmp_path, hz):
    mp = make_manifest(tmp_path, [64])
    with pytest.raises(SystemExit) as e:
        L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                "--dies", str(tmp_path / "dies.json"), "--hz", hz])
    assert e.value.code == 2

@pytest.mark.parametrize("hz", ["0", "-1"])
def test_cli_hz_refuses_zero_or_negative(tmp_path, hz):
    mp = make_manifest(tmp_path, [64])
    with pytest.raises(SystemExit) as e:
        L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                "--dies", str(tmp_path / "dies.json"), "--hz", hz])
    assert e.value.code == 2

def test_range_wait_budget_scales_with_hz():
    """Range-wait budgets already scale with t.hz (range_polls); this is the relationship
    --hz now actually controls end-to-end (test_cli_hz_override_reaches_the_transport)."""
    n = 1 << 20
    fast = L.range_polls(n, L.RANGE_EXPECT_BPS, 27_000_000)
    slow = L.range_polls(n, L.RANGE_EXPECT_BPS, 1_000_000)
    assert fast > slow >= L.MAX_POLLS

# ---------------------------------------------------------------- item 2: HBM calibration

def test_identify_timeout_message_mentions_hbm_calibration(tmp_path):
    frames, sha = plan(tmp_path, (64,))
    m = LoaderModel(dna=0, dna_valid=0)
    t = L.FakeTransport(m, lead=1)
    with pytest.raises(L.LoadAborted, match="HBM has not finished calibrating") as e:
        Ld(t, frames, sha, str(tmp_path / "ck.json"), dna=DNA_A).run_load()
    assert "LED_B" in str(e.value)

# ---------------------------------------------------------------- item 3: --max-resyncs + refill

def test_cli_max_resyncs_default_and_override(tmp_path, monkeypatch):
    mp = make_manifest(tmp_path, [64])
    seen = {}
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(LoaderModel(), lead=1))
    real_init = L.Loader.__init__
    def capturing_init(self, *a, **k):
        seen["max_resyncs"] = k.get("max_resyncs")
        return real_init(self, *a, **k)
    monkeypatch.setattr(L.Loader, "__init__", capturing_init)
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck.json")])
    assert rc == 0 and seen["max_resyncs"] == L.MAX_RESYNCS
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck2.json"), "--max-resyncs", "3"])
    assert rc == 0 and seen["max_resyncs"] == 3

@pytest.mark.parametrize("v", ["0", "-1"])
def test_cli_max_resyncs_refuses_below_one(tmp_path, v):
    mp = make_manifest(tmp_path, [64])
    with pytest.raises(SystemExit) as e:
        L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                "--dies", str(tmp_path / "dies.json"), "--max-resyncs", v])
    assert e.value.code == 2

def test_loader_refuses_max_resyncs_below_one(tmp_path):
    frames, sha = plan(tmp_path, (64,))
    t = L.FakeTransport(LoaderModel(), lead=1)
    with pytest.raises(ValueError, match="max_resyncs"):
        Ld(t, frames, sha, str(tmp_path / "ck.json"), max_resyncs=0)

def test_max_resyncs_budget_without_refill_is_bounded(tmp_path):
    """Direct on the budget/counting primitives (_count_retry/_budget), not through a
    full run_load(): the pipelined data phase can fold several failing frames into one
    resync (they are drained and resent together), so a scenario built out of N distinct
    fail_seqs does not reliably produce N distinct resyncs. The accounting itself is
    what item 3 changed, so test it directly."""
    frames, sha = plan(tmp_path, (64,))
    t = L.FakeTransport(LoaderModel(), lead=1)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"), max_resyncs=2)
    ld._count_retry("probe 1")
    ld._count_retry("probe 2")
    with pytest.raises(L.LoadAborted, match="resyncs"):
        ld._count_retry("probe 3")

def test_max_resyncs_budget_refills_per_100k_frames_committed(tmp_path):
    """Same bare max_resyncs=2 budget, but the die's status has shown 250,000 frames
    committed (as if this run resumed a long session): the refill rule (an extra
    --max-resyncs allowance per 100,000 data frames committed) must grant
    2 * (1 + 2) = 6 total before giving up, not the bare 2."""
    frames, sha = plan(tmp_path, (64,))
    t = L.FakeTransport(LoaderModel(), lead=1)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"), max_resyncs=2)
    ld.max_committed = 250_000
    assert ld._budget() == 6
    for i in range(6):
        ld._count_retry("probe %d" % i)          # must not raise: within the refilled budget
    with pytest.raises(L.LoadAborted, match="resyncs"):
        ld._count_retry("probe 7")               # the 7th exceeds even the refilled budget

# ---------------------------------------------------------------- item 4: bit-reversed DNA

def test_dna_bitrev_reverses_96_bits():
    assert L.dna_bitrev(0xFF) == 0xFF << 88
    assert L.dna_bitrev(1) == 1 << 95
    assert L.dna_bitrev(L.dna_bitrev(DNA_A)) == DNA_A

def test_identify_prints_the_bit_reversed_dna_without_changing_what_is_recorded(tmp_path, monkeypatch, capsys):
    p = str(tmp_path / "dies.json")
    monkeypatch.setattr(L, "CoeTransport", lambda *a, **k: L.FakeTransport(LoaderModel(dna=DNA_A), lead=1))
    rc = L.main(["identify", "--bmc", "192.0.2.1", "--chain", "AB", "--die", "A", "--dies", p])
    out = capsys.readouterr().out
    assert rc == 0
    assert L.dna_hex(DNA_A) in out
    assert L.dna_hex(L.dna_bitrev(DNA_A)) in out
    assert "bit-reversed" in out or "bitrev" in out
    assert "ESTIMATE" in out and "Task 11" in out
    assert L.read_dies(p) == {"A": DNA_A}          # the recorded value is NOT reversed

# ---------------------------------------------------------------- item 5: plan_frames outside the try

def test_cli_plan_error_prints_the_abort_sentinel_not_a_traceback(tmp_path, capsys):
    mp = make_manifest(tmp_path, [64])
    (tmp_path / "t0.bin").write_bytes(b"\xFF" * 64)         # now hashes wrong -> PlanError
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    rc = L.main(["load", mp, "--bmc", "192.0.2.1", "--die", "A", "--chain", "AB",
                 "--dies", dies, "--ckpt", str(tmp_path / "ck.json")])
    out, err = capsys.readouterr()
    assert rc == 2 and re_match_line(out, r"^JCLOAD_ABORT ")
    assert "Traceback" not in err and "Traceback" not in out

def test_cli_missing_manifest_prints_the_abort_sentinel_not_a_traceback(tmp_path, capsys):
    dies = dies_file(tmp_path, {"A": DEFAULT_DNA})
    rc = L.main(["load", str(tmp_path / "no_such_manifest.json"), "--bmc", "192.0.2.1",
                 "--die", "A", "--chain", "AB", "--dies", dies,
                 "--ckpt", str(tmp_path / "ck.json")])
    out, err = capsys.readouterr()
    assert rc == 2 and re_match_line(out, r"^JCLOAD_ABORT ")
    assert "Traceback" not in err and "Traceback" not in out

# ---------------------------------------------------------------- item 6: range CRC frozen at planning

def test_expected_range_crc_is_the_frozen_planning_value(tmp_path):
    """plan_frames computes each range frame's expected CRC once, during its hash pass
    (one read); expected_range_crc returns that stored value rather than re-reading."""
    mp, data = make_two_piece_manifest(tmp_path, 1000, 1048)
    frames, _ = L.plan_frames(mp)
    r0 = [f for f in frames if f.kind == "range" and f.addr == 0][0]
    assert r0.exp_crc == zlib.crc32(data[:1000] + bytes(24)) & 0xFFFFFFFF
    assert L.expected_range_crc(r0) == r0.exp_crc
    # Rewriting the file now must not change what expected_range_crc returns (frozen).
    (tmp_path / "striped.bin").write_bytes(bytes(len(data)))
    assert L.expected_range_crc(r0) == r0.exp_crc

def test_range_compare_uses_the_crc_frozen_at_planning_not_a_rewritten_file(tmp_path):
    """A file rewritten AFTER planning (consistently -- same length, so the manifest's
    own geometry still matches) used to still pass: expected_range_crc re-read the file
    at compare time, same as the payload re-read at send time, so both sides silently
    moved together and the blake2b check done at planning time meant nothing. The
    expected range CRC is now computed once during the planning hash pass and frozen on
    the Frame; the die commits the NEW bytes (read_payload reads live), so the range
    compare must now catch the mismatch rather than report DONE."""
    frames, sha = plan(tmp_path, (64,))
    fr = next(f for f in frames if f.kind == "data")
    data = open(fr.path, "rb").read()
    open(fr.path, "wb").write(bytes(b ^ 0xFF for b in data))   # same length, different bytes
    m = LoaderModel()
    ld = Ld(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json"))
    with pytest.raises(L.LoadAborted, match="range CRC"):
        ld.run_load()

def test_corrupt_seq_flips_one_payload_bit_once_and_the_load_recovers(tmp_path):
    """--corrupt-seq (Task 11 step 5, silicon fault injection): the named data frame goes
    out once with one payload bit flipped, the die's CRC check rejects it, the loader
    resyncs and resends it intact, and the die ends up holding the plan."""
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=0)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"), corrupt_seq=2)
    st = ld.run_load()
    assert st["last"] == frames[-1].seq
    assert ld.resyncs == 1 and st["crc_fail"] == 1
    assert_die_holds_the_plan(m, frames)

def test_corrupt_seq_refuses_a_range_frame(tmp_path):
    frames, sha = plan(tmp_path)
    rng = [f.seq for f in frames if f.kind == "range"][0]
    with pytest.raises(ValueError, match="data frame"):
        Ld(L.FakeTransport(LoaderModel(), lead=0), frames, sha, str(tmp_path / "ck.json"),
           corrupt_seq=rng)

def test_done_line_rate_counts_only_bytes_sent_this_run(tmp_path, capsys, monkeypatch):
    """MEASURED 2026-10-06 on silicon: after 7 resumed attempts the final attempt printed
    '40.54 MB/s', the whole plan's bytes over that one attempt's time. The rate must count
    only the data bytes this run actually sent."""
    frames, sha = plan(tmp_path, (5000, 64, 4096))
    m = LoaderModel()
    t = L.FakeTransport(m, lead=0)
    ld = Ld(t, frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    sent_all = ld.data_bytes_sent
    assert sent_all >= sum(f.n for f in frames if f.kind == "data")
    t2 = L.FakeTransport(m, lead=0)
    ld2 = Ld(t2, frames, sha, str(tmp_path / "ck.json"), resume=True)
    ld2.run_load()
    assert ld2.data_bytes_sent == 0             # nothing left to send on a complete die
