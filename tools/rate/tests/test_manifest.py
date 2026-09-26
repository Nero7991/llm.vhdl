import pytest, manifest

LEV = {"SWEEP_PIPE": {"top": "attn_block", "silicon": "unproven", "evidence": "build 21: 5 hangs in 90"}}

def base():
    return {"c_attn": {"top": "attn_block", "tier": "core", "clocks": {"clk": "*"},
                       "generics": {"SWEEP_PIPE": "false"}, "levers": ["SWEEP_PIPE"],
                       "extra_files": [], "target_ns": 10.0}}

def test_valid():
    manifest.validate(base(), LEV)

def test_lever_not_explicit_is_refused():
    d = base(); del d["c_attn"]["generics"]["SWEEP_PIPE"]
    with pytest.raises(SystemExit, match="explicit"):
        manifest.validate(d, LEV)

def test_lever_unknown_is_refused():
    d = base(); d["c_attn"]["levers"].append("NOPE"); d["c_attn"]["generics"]["NOPE"] = "true"
    with pytest.raises(SystemExit, match="levers.json"):
        manifest.validate(d, LEV)

def test_lever_listed_on_the_wrong_entity_is_refused():
    d = base(); d["other"] = dict(d["c_attn"]); d["other"]["top"] = "x"
    with pytest.raises(SystemExit, match="declared by"):
        manifest.validate(d, LEV)

def test_row_whose_top_owns_a_lever_must_list_it():
    d = base(); d["c_attn"]["levers"] = []
    with pytest.raises(SystemExit, match="must list"):
        manifest.validate(d, LEV)

def test_two_rows_same_top_both_explicit():
    d = base(); d["c_attn_levers"] = dict(d["c_attn"], generics={"SWEEP_PIPE": "true"})
    manifest.validate(d, LEV)

def test_bad_tier_is_refused():
    d = base(); d["c_attn"]["tier"] = "fast"
    with pytest.raises(SystemExit, match="tier"):
        manifest.validate(d, LEV)

def test_no_clock_is_refused():
    d = base(); d["c_attn"]["clocks"] = {}
    with pytest.raises(SystemExit, match="clock"):
        manifest.validate(d, LEV)


def test_target_for_a_plain_number_is_every_device():
    assert manifest.target_for({"target_ns": 2.5}, "vu35p_jc_m2") == 2.5


def test_target_for_a_map_names_the_device_or_falls_back_to_default():
    row = {"target_ns": {"default": 2.5, "vu35p_jc_m3": 2.0}}
    assert manifest.target_for(row, "vu35p_jc_m3") == 2.0
    assert manifest.target_for(row, "vu33p_fk33") == 2.5


def test_set_target_for_one_device_leaves_the_others_resolving_as_before(tmp_path):
    import json, calib
    p = tmp_path / "blocks.json"
    p.write_text(json.dumps({"r": {"target_ns": 2.5}}))
    calib.set_target("r", 1.9, "vu35p_jc_m1", path=str(p))
    row = json.loads(p.read_text())["r"]
    assert manifest.target_for(row, "vu35p_jc_m1") == 1.9
    assert manifest.target_for(row, "vu33p_fk33") == 2.5
