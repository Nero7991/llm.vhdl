import os, pytest, record

F = os.path.join(os.path.dirname(__file__), "fixtures")
def fx(n): return open(os.path.join(F, n)).read()

def test_parse_ok():
    p = record.parse_log(fx("rate_ok.log"))
    assert p["route"]["wns"] == 0.412 and p["route"]["unrouted"] == 0 and p["util"]["DSP"] == 64

def test_killed_run_gives_no_record():
    with pytest.raises(SystemExit, match="RATE_DONE"):
        record.parse_log(fx("rate_killed.log"))

def test_unrouted_is_refused():
    t = fx("rate_ok.log").replace("UNROUTED 0", "UNROUTED 3")
    with pytest.raises(SystemExit, match="unrouted"):
        record.parse_log(t)

def test_sentinel_must_be_line_anchored():
    t = "#  puts \"RATE_DONE route\"\n" + fx("rate_killed.log")
    with pytest.raises(SystemExit):
        record.parse_log(t)

def test_fmax():
    assert abs(record.fmax_mhz(5.0, 0.412) - 1000.0 / 4.588) < 1e-9

def test_lax_target_flagged():
    r = record.build("x", {"tier": "core", "levers": []}, "d", "p", "M", "k", [], 5.0,
                     record.parse_log(fx("rate_ok.log").replace("WNS 0.412", "WNS 1.500")), {})
    assert r["fmax_is_lower_bound"] is True

def test_pulse_width_ceiling():
    mhz = record.parse_pulse_width(fx("pulse_width.rpt"))
    assert mhz == pytest.approx(1000.0 / 0.550, rel=1e-6)

def test_record_path_distinct_per_device_and_model():
    assert record.path("a", "r", "M1") != record.path("b", "r", "M1") != record.path("a", "r", "M2")
