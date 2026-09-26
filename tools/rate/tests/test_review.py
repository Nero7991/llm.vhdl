"""Final-review findings (plan 2026-09-25-block-ratings), each pinned by a test."""
import pytest, rate, manifest


def test_a_misspelt_lever_value_refuses():
    # FAST_POP=flase would silently drop a_engine from rows_for and the stream tier from preflight.
    with pytest.raises(SystemExit, match="flase"):
        rate.parse_levers("FAST_POP=flase", manifest.load_levers())


def test_an_unknown_lever_name_refuses():
    with pytest.raises(SystemExit, match="SWEEP_PIPES"):
        rate.parse_levers("SWEEP_PIPES=true", manifest.load_levers())


def test_each_key_computation_gets_its_own_ghdl_library(monkeypatch):
    # status/ratestale and a lane rating the same row must not share a GHDL work library.
    seen = []
    real = rate.deps.elab_order
    def spy(tree, top, extra, workdir):
        seen.append(workdir)
        return real(tree, top, extra, workdir)
    monkeypatch.setattr(rate.deps, "elab_order", spy)
    row = manifest.row("d_vissue")
    rate.current_key("d_vissue", row, "xcvu33p-fsvh2104-2LV-e", manifest.target_for(row, "vu33p_fk33"))
    rate.current_key("d_vissue", row, "xcvu33p-fsvh2104-2LV-e", manifest.target_for(row, "vu33p_fk33"))
    assert len(set(seen)) == 2


def test_a_manifest_generic_the_entity_does_not_declare_refuses():
    row = dict(manifest.row("d_vissue"))
    row["generics"] = dict(row["generics"], NOT_A_GENERIC="1")
    with pytest.raises(SystemExit, match="NOT_A_GENERIC"):
        rate.current_key("d_vissue", row, "xcvu33p-fsvh2104-2LV-e", 1.0)


def test_the_private_probe_is_removed_after_the_key():
    import os
    row = manifest.row("d_vissue")
    sp0 = rate.current_key("d_vissue", row, "xcvu33p-fsvh2104-2LV-e", manifest.target_for(row, "vu33p_fk33"))[3]
    assert not os.path.exists(os.path.dirname(sp0))
