# hw/jc/card/jccard_const_allow.tcl -- from jccard2 (2026-10-07), sourced by build_card.tcl.
# Every GROUND/POWER input bit on the six module-reference cells that is constant BY
# DESIGN. Evidence per entry: hw/jc/card/results/jccard2_netlist_const_2026-10-07.md.
# Format: {<cell>/<port> <bit-lo> <bit-hi> <GROUND|POWER> "<reason>"}
#   <cell> is the short BD cell name (loader ctl eng fk33_seam_0 card bcgrant tok gtgclk).
#   A scalar port (pin name carries no [n]) is written with bit-lo = bit-hi = -1.
# Any constant bit NOT covered here (other port, other bit, or the other polarity)
# must still be refused. 729 bits total: 64 driver-constant, 655 unused, 10 dropped-resp;
# plus 5 driver-constant bits seen first on jccard9 (2026-10-10, c_awaddr[4:0]);
# plus 4 driver-constant bits on tok seen first on jccard_loop1 (2026-11-11, m_seam_bresp/rresp).
set JCC_CONST_ALLOW {
  {bcgrant/b_awlen        0   3 POWER  "B state write burst awlen = MAXB-1 = 15 (gdn_state_axi.vhd:353)"}
  {bcgrant/b_awlen        4   7 GROUND "AXI3 awlen <= 15 (gdn_state_axi.vhd:353)"}
  {bcgrant/b_arlen        4   7 GROUND "AXI3 arlen <= 15: norm fetch blen-1 / store MAXB-1 (fk33_llama_top.vhd:1866,4084)"}
  {bcgrant/c0_arlen       4   7 GROUND "AXI3 arlen <= 15: alen 1..16 (attn_kv_axi.vhd:706,749)"}
  {bcgrant/c1_arlen       4   7 GROUND "AXI3 arlen <= 15: alen 1..16 (attn_kv_axi.vhd:706,749)"}
  {bcgrant/c0_rready     -1  -1 POWER  "KV r_rready tied high by design (attn_kv_axi.vhd:569)"}
  {bcgrant/c1_rready     -1  -1 POWER  "KV r_rready tied high by design (attn_kv_axi.vhd:569)"}
  {bcgrant/c_bready      -1  -1 POWER  "KV w_bready tied high by design (attn_kv_axi.vhd:570)"}
  {bcgrant/c_awaddr       0   4 GROUND "KV write bursts start beat-aligned: astart = a0 - low_bits(a0, BEAT_LW), then astart + bi*BEAT_B (attn_kv_axi.vhd:1066-1067,1107); seen first on jccard9"}
  {card/a_y_addr          0   3 GROUND "y_addr = tile*48, multiple of 16 (matvec_core.vhd:1106,1300; fk33_engine.vhd:1115)"}
  {card/hw_reg            0   3 GROUND "seam drives XREG = 0 = R_X; only host-written region at 27B (fk33_seam.vhd:198,751)"}
  {card/hr_reg            0   3 GROUND "seam drives XREG = 0 = R_X (fk33_seam.vhd:754); HOST_WINDOW false"}
  {eng/job_index          9  31 GROUND "a_job_counter n in 0..A_N_JOBS=311 < 512 (a_job_counter.vhd:133,142)"}
  {fk33_seam_0/d_raddr   14  15 GROUND "fetch_idx(11b)&000 + beat(0..7) < 2^14 (seq_desc_fetch.vhd:290,291,576)"}
  {fk33_seam_0/obs_tok_pos 14 15 GROUND "tok_pos < C_MAXPOS = 16384 (fk33_llama_top.vhd:1434,8359)"}
  {fk33_seam_0/smp_token 31  31 GROUND "token guarded non-negative (fk33_llama_top.vhd:8573)"}
  {fk33_seam_0/f_unit_stub -1 -1 GROUND "f_stub set only under not C_REAL; C_REAL true (fk33_llama_top.vhd:7151,7182)"}
  {card/m_arready         0   4 GROUND "UNUSED: sim-path A master, read only in ga_real, removed at A_DESC=true (fk33_llama_top.vhd:5437)"}
  {card/m_rvalid          0   4 GROUND "UNUSED: sim-path A master, removed at A_DESC=true (fk33_llama_top.vhd:5437)"}
  {card/m_rdata           0 639 GROUND "UNUSED: sim-path A master, removed at A_DESC=true (fk33_llama_top.vhd:5437)"}
  {card/m_rlast           0   4 GROUND "UNUSED: sim-path A master, removed at A_DESC=true (fk33_llama_top.vhd:5437)"}
  {card/bst_rresp         0   1 GROUND "DROPPED-RESPONSE: grant carries no rresp; B store/norm-fetch error detection is blind"}
  {card/bst_bresp         0   1 GROUND "DROPPED-RESPONSE: grant carries no bresp; B store write error detection is blind"}
  {card/kv0_rresp         0   1 GROUND "DROPPED-RESPONSE: grant carries no rresp; C KV read error detection is blind"}
  {card/kv1_rresp         0   1 GROUND "DROPPED-RESPONSE: grant carries no rresp; C KV read error detection is blind"}
  {card/kv_bresp          0   1 GROUND "DROPPED-RESPONSE: grant carries no bresp; C KV write error detection is blind"}
  {tok/m_seam_bresp       0   1 GROUND "fk33_seam's AXI-Lite slave answers every write OKAY: s_axi_bresp <= \"00\" (fk33_seam.vhd:763), wired tok/m_seam -> fk33_seam_0/s_axi (jc_card_bd.tcl:782); jc_seam_mux latches m_bresp (jc_seam_mux.vhd:167), so tok_loop_axm sees SLVERR only from its own timeout (\"11\", tok_loop_axm.vhd:84)"}
  {tok/m_seam_rresp       0   1 GROUND "fk33_seam's AXI-Lite slave answers every read OKAY: s_axi_rresp <= \"00\" (fk33_seam.vhd:771), wired tok/m_seam -> fk33_seam_0/s_axi (jc_card_bd.tcl:782); jc_seam_mux latches m_rresp (jc_seam_mux.vhd:171), so tok_loop_axm sees SLVERR only from its own timeout (\"11\", tok_loop_axm.vhd:84)"}
}

# jcc_const_allowed <pin> <GROUND|POWER>: 1 if <pin> (a full hierarchical pin name
# ending in <cell>/<port> or <cell>/<port>[n]) is on JCC_CONST_ALLOW with that
# polarity and inside that bit range, else 0. No wildcards: a scalar entry (-1 -1)
# matches only a scalar pin, a vector entry only bits lo..hi.
proc jcc_const_allowed {pin type} {
  global JCC_CONST_ALLOW
  if {[regexp {([^/]+/[^/\[]+)\[([0-9]+)\]$} $pin -> cp bit]} {
  } elseif {[regexp {([^/]+/[^/\[]+)$} $pin -> cp]} {
    set bit -1
  } else { return 0 }
  foreach e $JCC_CONST_ALLOW {
    lassign $e ecp lo hi etype
    if {$ecp ne $cp || $etype ne $type} continue
    if {$lo == -1} { if {$bit == -1} { return 1 } ; continue }
    if {$bit >= $lo && $bit <= $hi} { return 1 }
  }
  return 0
}
