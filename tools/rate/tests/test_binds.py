import os, pytest, binds
F = os.path.join(os.path.dirname(__file__), "fixtures", "binds_9b.txt")
KV = "u/gcr.gkvaxi.u_kv"      # the instance name in the RTL-elaborated fk33_card (dots join generate labels)

def test_kv_generics_match_the_9b_card():
    b = binds.parse(open(F).read())
    g = binds.for_row(b, KV, ["HEAD_DIM", "KV_BLOCK", "N_KVH"])
    assert g == {"HEAD_DIM": "256", "KV_BLOCK": "32", "N_KVH": "4"}

def test_missing_done_refused():
    with pytest.raises(SystemExit, match="BIND_DONE"):
        binds.parse("BIND u_kv HEAD_DIM 256\n")

def test_missing_generic_refused():
    b = binds.parse(open(F).read())
    with pytest.raises(SystemExit, match="lacks"):
        binds.for_row(b, KV, ["NOT_A_GENERIC"])

def test_vhdl_literal_by_declared_type():
    # Vivado prints booleans as TRUE and strings unquoted (MEASURED 2026-09-25)
    assert binds.vhdl_literal("TRUE", "boolean") == "true"
    assert binds.vhdl_literal("ultra", "string") == '"ultra"'
    assert binds.vhdl_literal("256", "positive") == "256"
    with pytest.raises(SystemExit, match="type"):
        binds.vhdl_literal("x", "std_logic_vector(3 downto 0)")

def test_generics_for_an_instance_uses_the_entity_declarations():
    import config
    b = binds.parse(open(F).read())
    ent = open(os.path.join(config.REPO, "rtl", "attn_kv_axi.vhd")).read()
    g = binds.generics_for(b, KV, "attn_kv_axi", ent)
    assert len(g) == 13 and g["HEAD_DIM"] == "256" and g["MAXCTX"] == "65536" and g["POS_W"] == "17"

def test_real_literal_keeps_a_decimal_point():
    assert binds.vhdl_literal("1", "real") == "1.0"
    assert binds.vhdl_literal("0.000001", "real") == "1.0e-06"   # VHDL needs the point

def test_integer_vector_decodes_32_bit_chunks_element_0_first():
    # MEASURED 2026-09-25: u_lock REG_SIZE prints as 448'b...; its first chunks are 4096, 4096, 8192
    v = "96'b" + format(4096, "032b") + format(4096, "032b") + format(8192, "032b")
    assert binds.vhdl_literal(v, "integer_vector") == "(4096, 4096, 8192)"

def test_integer_vector_single_element_uses_named_association():
    assert binds.vhdl_literal("32'b" + format(7, "032b"), "integer_vector") == "(0 => 7)"

def test_integer_vector_negative():
    assert binds.vhdl_literal("32'b" + format((1 << 32) - 3, "032b"), "integer_vector") == "(0 => -3)"
