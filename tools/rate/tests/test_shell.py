import os, subprocess
import pytest, shell, deps, config

KV = {"top": "attn_kv_axi", "tier": "core", "clocks": {"clk": "*"}, "levers": [], "extra_files": [],
      "target_ns": 5.0,
      "generics": {"HEAD_DIM": "256", "KV_BLOCK": "32", "N_KVH": "4", "LAYERS": "8", "MAXCTX": "65536",
                   "POS_W": "17", "CM_W": "8", "EXP_W": "8", "AXI_DW": "256", "ADDR_W": "33",
                   "MAXB": "16", "MAXOUT": "4", "RBUF": "4"}}

def src(name):
    return open(os.path.join(config.REPO, "rtl", name + ".vhd")).read()

def test_parse_attn_kv_axi():
    e = shell.parse_entity(src("attn_kv_axi"), "attn_kv_axi")
    names = [g[0] for g in e["generics"]]
    assert names[:3] == ["HEAD_DIM", "KV_BLOCK", "N_KVH"]
    pn = [p[0] for p in e["ports"]]
    assert "clk" in pn and "rst" in pn
    assert all(p[1] in ("in", "out") for p in e["ports"])

def test_refuses_inout():
    t = "library ieee; use ieee.std_logic_1164.all;\nentity e is port(clk : in std_logic; b : inout std_logic); end entity;"
    with pytest.raises(SystemExit, match="inout"):
        shell.gen_shell({"top": "e", "clocks": {"clk": "*"}, "generics": {}}, t)

def test_shell_registers_every_port():
    v = shell.gen_shell(KV, src("attn_kv_axi"))
    e = shell.parse_entity(src("attn_kv_axi"), "attn_kv_axi")
    for (n, mode, _) in e["ports"]:
        if n == "clk":
            continue
        assert ("%s_q" % n) in v, n

def test_shell_analyses_and_elaborates_under_ghdl(tmp_path):
    v = shell.gen_shell(KV, src("attn_kv_axi"))
    sp = tmp_path / "rate_shell.vhd"; sp.write_text(v)
    order = deps.elab_order(config.REPO, "rate_shell", (str(sp),), str(tmp_path / "w"))
    assert order[-1] == str(sp)
    common = ["--std=08", "-frelaxed", "--workdir=%s" % (tmp_path / "w")]
    for f in order:
        r = subprocess.run(["ghdl", "-a"] + common + [f], cwd=config.REPO, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
    r = subprocess.run(["ghdl", "-r"] + common + ["rate_shell", "--stop-time=1ns"],
                       cwd=config.REPO, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

def test_entity_without_generics():
    t = ("library ieee; use ieee.std_logic_1164.all;\n"
         "entity g0 is port(clk : in std_logic; a : in std_logic; y : out std_logic); end entity;")
    v = shell.gen_shell({"top": "g0", "clocks": {"clk": "*"}, "generics": {}}, t)
    assert "generic(" not in v and "generic map" not in v
    assert "a_q" in v and "y_q" in v


def test_shell_text_does_not_depend_on_the_hash_seed():
    # MEASURED 2026-09-25: a_engine's key flipped between runs because gen_shell iterated a
    # set of clock names, whose order follows PYTHONHASHSEED; the shell text is in the key.
    import subprocess, sys
    code = ("import sys, json; sys.path.insert(0, %r); import manifest, rate, shell; "
            "r = manifest.row('a_engine'); print(shell.gen_shell(r, rate.entity_text(rate.config.REPO, r)))"
            % os.path.join(os.path.dirname(__file__), ".."))
    outs = {subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True,
                           env=dict(os.environ, PYTHONHASHSEED=str(s))).stdout for s in range(8)}
    assert len(outs) == 1
