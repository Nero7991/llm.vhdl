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

def test_any_met_target_is_a_lower_bound():
    # Vivado stops optimising once timing is met: MEASURED 2026-09-25, calib depth 3 met a
    # 1.5 ns target at 765 MHz while depth 4, also met, reached 807 MHz.
    p = record.parse_log(fx("rate_ok.log").replace("WNS 0.412", "WNS 0.100"))
    r = record.build("x", {"tier": "core", "levers": []}, "d", "p", "M", "k", [], 5.0, p, {})
    assert r["fmax_is_lower_bound"] is True

def test_overconstrained_run_is_a_rating():
    p = record.parse_log(fx("rate_ok.log").replace("WNS 0.412", "WNS -0.300"))
    r = record.build("x", {"tier": "core", "levers": []}, "d", "p", "M", "k", [], 5.0, p, {})
    assert r["fmax_is_lower_bound"] is False
    assert r["achieved_mhz"] == pytest.approx(1000.0 / 5.3)

def test_achieved_is_capped_at_the_ceiling():
    # MEASURED 2026-09-25: calib depth 1 routed 1887 MHz against a 1818 MHz FDRE min period.
    p = record.parse_log(fx("rate_ok.log").replace("WNS 0.412", "WNS 0.010"))
    r = record.build("x", {"tier": "core", "levers": []}, "d", "p", "M", "k", [], 0.54, p, {}, ceiling=1818.2)
    assert r["achieved_mhz"] == pytest.approx(1818.2)
    assert r["limited_by"] == "ceiling"
    assert r["fmax_is_lower_bound"] is False
    assert r["route_mhz"] == pytest.approx(1000.0 / 0.53)
