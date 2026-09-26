import os, subprocess, sys, types
import pytest, vivado

RATE = os.path.join(os.path.dirname(__file__), "..", "rate.py")


def fake_run(stdout):
    return lambda *a, **k: types.SimpleNamespace(stdout=stdout, returncode=0)


def test_bc250_host_reads_the_address_from_the_lease(monkeypatch):
    lease = "78626 40:a5:ef:5f:0a:79 192.0.2.133 cachyos-bc250 01:40:a5:ef:5f:0a:79\n"
    monkeypatch.setattr(vivado.subprocess, "run", fake_run(lease))
    assert vivado.bc250_host() == "192.0.2.133"


def test_bc250_host_refuses_without_a_lease(monkeypatch):
    monkeypatch.setattr(vivado.subprocess, "run", fake_run(""))
    with pytest.raises(SystemExit, match="lease"):
        vivado.bc250_host()


def test_bc250_refuses_a_cap_above_11g_before_touching_the_network(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("network touched")
    monkeypatch.setattr(vivado.subprocess, "run", boom)
    with pytest.raises(SystemExit, match="11G"):
        vivado.run_batch_bc250("x.tcl", [], "/mnt/storage/fk33_builds/ratings/x", mem_high="12G")


def test_bc250_lane_refuses_a_tree_other_than_the_repo(tmp_path):
    r = subprocess.run([sys.executable, RATE, "run", "c_kv", "--device", "vu33p_fk33", "--model", "QWEN35_9B",
                        "--lane", "bc250", "--tree", str(tmp_path)], capture_output=True, text=True)
    assert r.returncode != 0 and "only the repo is synced" in (r.stdout + r.stderr)
