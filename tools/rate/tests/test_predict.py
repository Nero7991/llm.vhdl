import pytest, predict

T = {"lut": {1: 800.0, 2: 650.0, 4: 480.0, 8: 300.0, 12: 220.0}}

def test_measured_point():
    assert predict.structural_mhz(4, T) == (480.0, "measured")

def test_interpolates_in_period():
    mhz, how = predict.structural_mhz(6, T)
    assert how == "measured"
    assert mhz == pytest.approx(1000.0 / ((1000/480 + 1000/300) / 2))

def test_beyond_calibration_is_labelled():
    assert predict.structural_mhz(15, T)[1] == "beyond-calibration"

def test_max_levels():
    assert predict.max_levels(300.0, T) == 8
    assert predict.max_levels(1000.0, T) == 0

def test_table_must_be_monotone():
    with pytest.raises(SystemExit, match="monotone"):
        predict.check({"lut": {1: 500.0, 2: 600.0}})


def test_max_levels_is_unbounded_below_the_slowest_calibrated_depth():
    # MEASURED 2026-09-26: v_swg routes 32 levels at 83.4 MHz; a table ending at depth 12
    # (424 MHz) cannot bound the depth of an 80 MHz clock, so it must not refuse on it.
    t = {"lut": {1: 1800.0, 12: 424.0}}
    assert predict.max_levels(80.0, t) is None
    assert predict.max_levels(500.0, t) == 1
