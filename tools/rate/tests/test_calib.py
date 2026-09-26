import os
import pytest, calib

def test_next_target_is_85_percent_of_the_achieved_period():
    # depth 3, 2026-09-25: target 1.11 ns met with WNS +0.127 -> achieved period 0.983 ns
    assert calib.next_target(1.11, 0.127) == pytest.approx(0.85 * 0.983)

def test_next_target_refuses_an_unmet_run():
    with pytest.raises(ValueError):
        calib.next_target(1.0, -0.2)


def test_set_target_from_two_processes_loses_no_update(tmp_path):
    # Two lanes retarget concurrently (Task 11): the read-modify-write must be serialised.
    import json, subprocess, sys
    p = tmp_path / "blocks.json"
    p.write_text(json.dumps({"a": {"target_ns": 2.0}, "b": {"target_ns": 2.0}}))
    code = ("import sys; sys.path.insert(0, %r); import calib\n"
            "for i in range(150): calib.set_target(sys.argv[1], 1.0 + i / 1000, 'dev%%d' %% i, path=%r)"
            % (os.path.join(os.path.dirname(__file__), ".."), str(p)))
    procs = [subprocess.Popen([sys.executable, "-c", code, r]) for r in ("a", "b")]
    assert all(q.wait() == 0 for q in procs)
    d = json.loads(p.read_text())
    assert len(d["a"]["target_ns"]) == 151 and len(d["b"]["target_ns"]) == 151
