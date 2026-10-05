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
