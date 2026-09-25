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
