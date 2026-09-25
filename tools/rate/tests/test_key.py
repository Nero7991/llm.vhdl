import os, shutil, subprocess
import pytest, deps, key, config

ROW = {"top": "attn_kv_axi", "generics": {"HEAD_DIM": "256"}, "levers": [], "clocks": {"clk": "*"}}

@pytest.fixture
def tree(tmp_path):
    t = tmp_path / "tree"
    for d in config.RTL_DIRS:
        shutil.copytree(os.path.join(config.REPO, d), t / d)
    return str(t)

def test_elab_order_of_attn_kv_axi(tree, tmp_path):
    got = deps.elab_order(tree, "attn_kv_axi", (), str(tmp_path / "w"))
    assert got == ["rtl/util_pkg.vhd", "rtl/attn_kv_axi.vhd"]    # MEASURED 2026-09-25, ghdl 1.0.0

def k(tree, tmp_path):
    d = deps.elab_order(tree, "attn_kv_axi", (), str(tmp_path / "w"))
    return key.rating_key(tree, d, "shell", ROW, "xcvu33p-fsvh2104-2LV-e", 5.0, [])

def test_key_changes_when_a_dependency_changes(tree, tmp_path):
    a = k(tree, tmp_path)
    with open(os.path.join(tree, "rtl/util_pkg.vhd"), "a") as f:
        f.write("\n-- teeth\n")
    assert k(tree, tmp_path) != a

def test_key_unchanged_when_an_unread_file_changes(tree, tmp_path):
    a = k(tree, tmp_path)
    with open(os.path.join(tree, "rtl/gdn_block.vhd"), "a") as f:     # not read by attn_kv_axi
        f.write("\n-- control\n")
    assert k(tree, tmp_path) == a

def test_key_changes_with_part_target_generics(tree, tmp_path):
    d = deps.elab_order(tree, "attn_kv_axi", (), str(tmp_path / "w"))
    base = key.rating_key(tree, d, "shell", ROW, "p1", 5.0, [])
    assert key.rating_key(tree, d, "shell", ROW, "p2", 5.0, []) != base
    assert key.rating_key(tree, d, "shell", ROW, "p1", 4.0, []) != base
    r2 = dict(ROW, generics={"HEAD_DIM": "128"})
    assert key.rating_key(tree, d, "shell", r2, "p1", 5.0, []) != base
