import os, subprocess, sys
RATE = os.path.join(os.path.dirname(__file__), "..", "rate.py")


def test_status_runs_and_summarises():
    r = subprocess.run([sys.executable, RATE, "status"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert any(l.startswith("RATESTALE_SUMMARY ") for l in r.stdout.splitlines())
