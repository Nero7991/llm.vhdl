import pytest, tiers

RECS = [{"row": "c_attn", "tier": "core", "achieved_mhz": 120.0},
        {"row": "d_fetch", "tier": "core", "achieved_mhz": 250.0},
        {"row": "a_engine", "tier": "stream", "achieved_mhz": 210.0}]


def test_tier_min():
    assert tiers.tier_min(RECS, "core") == (120.0, "c_attn")


def test_k_from_a_build_that_met_timing_is_a_lower_bound():
    k = tiers.k_from_build(13.333, 0.032, 120.0)
    assert k["lower_bound"] is True
    assert k["k"] == pytest.approx((1000 / (13.333 - 0.032)) / 120.0)


def test_k_from_a_failing_build_is_exact():
    assert tiers.k_from_build(5.0, -1.0, 200.0)["lower_bound"] is False


def test_predict_uses_worst_k():
    kf = {"core": [{"k": 0.7, "lower_bound": False}, {"k": 0.6, "lower_bound": True}],
          "stream": [{"k": 0.5, "lower_bound": True}]}
    assert tiers.predict(RECS, kf)["core"] == pytest.approx(0.6 * 120.0)


def test_predict_refuses_without_k():
    with pytest.raises(SystemExit, match="first card build"):
        tiers.predict(RECS, {})


def test_unproven_lever_refused():
    import rate
    with pytest.raises(SystemExit, match="silicon"):
        rate.lever_gate({"SWEEP_PIPE": "true"},
                        {"SWEEP_PIPE": {"top": "attn_block", "silicon": "unproven", "evidence": ""}}, proving=())


def test_proving_build_may_turn_one_on():
    import rate
    rate.lever_gate({"SWEEP_PIPE": "true"},
                    {"SWEEP_PIPE": {"top": "attn_block", "silicon": "unproven", "evidence": ""}},
                    proving=("SWEEP_PIPE",))


def test_predict_ignores_anchor_rows():
    recs = RECS + [{"row": "c_mover", "tier": "anchor", "achieved_mhz": 10.0}]
    kf = {"core": [{"k": 1.0, "lower_bound": True}], "stream": [{"k": 1.0, "lower_bound": True}]}
    assert set(tiers.predict(recs, kf)) == {"core", "stream"}


def test_rows_for_selects_the_arm_each_lever_value_ships():
    import rate
    rows = {"c_attn": {"levers": ["SWEEP_PIPE"], "generics": {"SWEEP_PIPE": "false"}},
            "c_attn_levers": {"levers": ["SWEEP_PIPE"], "generics": {"SWEEP_PIPE": "true"}},
            "d_fetch": {"levers": [], "generics": {}}}
    assert sorted(rate.rows_for(rows, {"SWEEP_PIPE": "false"})) == ["c_attn", "d_fetch"]
    assert sorted(rate.rows_for(rows, {"SWEEP_PIPE": "true"})) == ["c_attn_levers", "d_fetch"]


def test_rows_for_refuses_a_lever_the_build_does_not_name():
    import rate
    rows = {"c_attn": {"levers": ["SWEEP_PIPE"], "generics": {"SWEEP_PIPE": "false"}}}
    with pytest.raises(SystemExit, match="SWEEP_PIPE"):
        rate.rows_for(rows, {})
