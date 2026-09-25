import json, pytest
import devices

GOOD = {"vu33p_fk33": {"build_part": "xcvu33p-fsvh2104-2L-e",
                       "rating_part": "xcvu33p-fsvh2104-2LV-e",
                       "vccint_run": 0.715, "board": "fk33", "resources": None}}

def test_validate_accepts_unrefreshed_row():
    devices.validate(GOOD)

def test_validate_refuses_missing_field():
    bad = {"x": {"build_part": "p"}}
    with pytest.raises(SystemExit, match="missing"):
        devices.validate(bad)

def test_validate_refuses_hand_typed_resources():
    bad = json.loads(json.dumps(GOOD))
    bad["vu33p_fk33"]["resources"] = {"LUT": 439680, "FF": 879360, "BRAM": 672, "URAM": 320, "DSP": 2880}
    with pytest.raises(SystemExit, match="_source"):
        devices.validate(bad)

def test_parse_partprops():
    text = ("junk\nPARTPROP xcvu33p-fsvh2104-2LV-e LUT 439680 FF 879360 BRAM 672 URAM 320 DSP 2880\n"
            "PARTPROP_MISSING xcvu99p\nPARTPROP_DONE\n")
    got = devices.parse_partprops(text)
    assert got == {"xcvu33p-fsvh2104-2LV-e": {"LUT": 439680, "FF": 879360, "BRAM": 672, "URAM": 320, "DSP": 2880}}

def test_parse_partprops_refuses_without_done():
    with pytest.raises(SystemExit, match="PARTPROP_DONE"):
        devices.parse_partprops("PARTPROP a LUT 1 FF 1 BRAM 1 URAM 1 DSP 1\n")

def test_refresh_writes_sourced_resources(tmp_path):
    p = tmp_path / "devices.json"; p.write_text(json.dumps(GOOD))
    log = ("PARTPROP xcvu33p-fsvh2104-2LV-e LUT 439680 FF 879360 BRAM 672 URAM 320 DSP 2880\n"
           "PARTPROP xcvu33p-fsvh2104-2L-e LUT 439680 FF 879360 BRAM 672 URAM 320 DSP 2880\nPARTPROP_DONE\n")
    fake = lambda tcl, args, wd, mem, unit: {"log": log}
    d = devices.refresh(str(p), fake)
    assert d["vu33p_fk33"]["resources"]["LUT"] == 439680
    assert d["vu33p_fk33"]["resources"]["_source"].startswith("vivado ")
    assert json.loads(p.read_text())["vu33p_fk33"]["resources"]["DSP"] == 2880

def test_refresh_refuses_a_part_vivado_lacks(tmp_path):
    p = tmp_path / "devices.json"; p.write_text(json.dumps(GOOD))
    fake = lambda tcl, args, wd, mem, unit: {"log": "PARTPROP_MISSING xcvu33p-fsvh2104-2LV-e\nPARTPROP_DONE\n"}
    with pytest.raises(SystemExit, match="no part"):
        devices.refresh(str(p), fake)
