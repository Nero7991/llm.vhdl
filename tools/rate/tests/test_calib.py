import pytest, calib

def test_next_target_is_85_percent_of_the_achieved_period():
    # depth 3, 2026-09-25: target 1.11 ns met with WNS +0.127 -> achieved period 0.983 ns
    assert calib.next_target(1.11, 0.127) == pytest.approx(0.85 * 0.983)

def test_next_target_refuses_an_unmet_run():
    with pytest.raises(ValueError):
        calib.next_target(1.0, -0.2)
