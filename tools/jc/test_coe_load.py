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
