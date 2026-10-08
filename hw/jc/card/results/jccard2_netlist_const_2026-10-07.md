# jccard2 netlist constant-input classification (2026-10-07)

Source: `jccard2-netlist-const.txt` (729 `JCCARD_NETLIST_CONST` lines from
`hw/jc/card/build_card.tcl:243-260`). All RTL citations are against the built tree
`/mnt/storage/fk33_builds/jccard2/src` (HEAD 957e0f0c + build12_levers_off.patch +
regenerated 27B `hw/fk33/rtl/fk33_card.vhd`). Paths below are relative to that tree.
Cell prefix `u_bd/jcc_i/` omitted. Read-only analysis; no Vivado or GHDL was run.

## Counts

| Class | Groups | Bits |
|---|---|---|
| BENIGN-DRIVER-CONSTANT | 16 | 64 |
| BENIGN-UNUSED | 4 | 655 |
| DROPPED-RESPONSE | 5 | 10 |
| DEFECT | 0 | 0 |
| **Total** | **25** | **729** |

## Table

| cell/port | bits | n | type | class | evidence (file:line) | reason |
|---|---|---|---|---|---|---|
| bcgrant/b_arlen | 7:4 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:685` from card/bst_arlen; `rtl/fk33_llama_top.vhd:1866` mux of `nf_arlen` (`:4084`, `blen-1`, blen range 1..16 `:4067`) and store `bst_arlen_i` = `MAXB-1` (`rtl/gdn_state_axi.vhd:346`, MAXB = `BST_MAXB` = min4(16,..) `rtl/fk33_llama_top.vhd:6206`, mapped `:6440`) | AXI3 len <= 15; upper nibble always 0. [3:0] are live (norm fetch vs store) |
| bcgrant/b_awlen | 7:4 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:693`; `rtl/gdn_state_axi.vhd:353` `w_awlen <= MAXB-1`, via `rtl/gdn_state_store.vhd:652` and `rtl/fk33_llama_top.vhd:1834`; BST_MAXB = 16 at 27B (`:6206`) | every B state write burst is 16 beats: awlen = 0x0F |
| bcgrant/b_awlen | 3:0 | 4 | POWER | BENIGN-DRIVER-CONSTANT | same as above | awlen = 15 = 0b1111 |
| bcgrant/c0_arlen | 7:4 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:703`; `rtl/attn_kv_axi.vhd:749` `r_arlen <= alen-1`, `alen : integer range 1 to MAXB` `:706`; MAXB = C_KV_MAXB = 16 `rtl/fk33_llama_top.vhd:729`, `:7824` | AXI3 len <= 15 |
| bcgrant/c1_arlen | 7:4 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:711`; same driver as c0 (`rtl/attn_kv_axi.vhd:749`, slice s=1) | AXI3 len <= 15 |
| bcgrant/c0_rready | scalar | 1 | POWER | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:705`; `rtl/attn_kv_axi.vhd:569` `r_rready <= "11"` | KV read always ready, by design (SECTION 7 comment `:565-568`) |
| bcgrant/c1_rready | scalar | 1 | POWER | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:713`; `rtl/attn_kv_axi.vhd:569` | same |
| bcgrant/c_bready | scalar | 1 | POWER | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:725`; `rtl/attn_kv_axi.vhd:570` `w_bready <= '1'` | KV write response always accepted |
| card/a_y_addr | 3:0 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:593` from eng/d_y_addr; `hw/fk33/rtl/fk33_engine.vhd:1315`, ROWS_IF = 48 `:1115`; `rtl/matvec_core.vhd:1106,1163,1300,1302` `y_addr <= rbase`, `rbase := tile*ROWS_IF` | 48 = 0b110000: tile base row is always a multiple of 16. Receiver divides by 48 (`rtl/fk33_llama_top.vhd:5232`), consistent |
| card/hw_reg | 3:0 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:669`; `rtl/fk33_seam.vhd:751` `hw_reg <= to_unsigned(XREG,..)`, XREG default 0 `:198`, not overridden (BD sets only REGMAX/HADDR_W/CAPS_*/MAXPOS/CAP_NORM_HBM, `jc_card_bd.tcl:460,513-518`); R_X = 0 `rtl/llama_map_pkg.vhd:72` | host writes only the token embedding into R_X (`rtl/fk33_llama_top.vhd:1022`). Norm gains come from HBM (`NORM_HBM => true`, `hw/fk33/rtl/fk33_card.vhd:243`; `rtl/fk33_llama_top.vhd:4050`), B constants from HBM (B_CONST_HBM). No host-written table beyond reg 0 exists at 27B. Same seam RTL as the FK33 cards |
| card/hr_reg | 3:0 | 4 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:672`; `rtl/fk33_seam.vhd:754` (XREG = 0) | host reads back R_X only; and `HOST_WINDOW => false` (`hw/fk33/rtl/fk33_card.vhd:239`) makes hr_data read zero regardless (`rtl/fk33_llama_top.vhd:946-953`) |
| eng/job_index | 31:9 | 23 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:587` from card/a_job_index; `rtl/a_job_counter.vhd:133` `n : natural range 0 to N_JOBS`, `:142` `job_index <= to_unsigned(n,32)`; N_JOBS = A_N_JOBS = 311 (`rtl/fk33_llama_top.vhd:972`, mapped `:5118`; not overridden in `hw/fk33/rtl/fk33_card.vhd:233-256`) | 311 < 512, so 9 bits. 311 is the 9B-derived arena size; 27B per-die programs are 306 and 302 A jobs (`docs/WORKLOG.md:121`, not re-verified here), within it; shorter arena accepted (`tools/gen_layer_program.py:1536-1541`), overrun refused (`rtl/a_desc_adapter.vhd:230`) |
| fk33_seam_0/d_raddr | 15:14 | 2 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:645`; `rtl/seq_desc_fetch.vhd:576` `resize(fetch_idx & "000",16) + f_beat`, fetch_idx STEP_W = 11 bits `:291`, f_beat 0..7 `:290` | max 2047*8+7 = 16383 < 2^14 |
| fk33_seam_0/obs_tok_pos | 15:14 | 2 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:649`; `rtl/fk33_llama_top.vhd:8359` `to_unsigned(tok_pos,16)`, `tok_pos : natural range 0 to C_MAXPOS-1` `:1434`; C_MAXPOS = 16384 `hw/fk33/rtl/fk33_card.vhd:251` | position < 2^14 |
| fk33_seam_0/smp_token | 31 | 1 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:650`; `rtl/fk33_llama_top.vhd:8573` `to_unsigned(s_tok,32) when s_tok >= 0 else 0` | non-negative integer, bit 31 never set |
| fk33_seam_0/f_unit_stub | scalar | 1 | GROUND | BENIGN-DRIVER-CONSTANT | BD `jc_card_bd.tcl:657` from card/err_unit_stub; `rtl/fk33_llama_top.vhd:8607` `err_unit_stub <= f_stub`; only setter `:7182` is inside `gc : if not C_REAL generate` `:7151`; `C_REAL => true` `hw/fk33/rtl/fk33_card.vhd:240` | no stub unit in this build, flag correctly folds to 0 |
| card/m_arready | 4:0 | 5 | GROUND | BENIGN-UNUSED | BD has no `card/m_*` connection (grep `jc_card_bd.tcl`); read only in `ga_real : if not A_BEHAV and not A_DESC generate` `rtl/fk33_llama_top.vhd:5437`, port map `:5572`; `A_DESC => true` `hw/fk33/rtl/fk33_card.vhd:234` (`hw/fk33/gen_fk33_card.py:165`) | simulation-path A weight master, removed at A_DESC; outputs tied in `ga_tie` `:4924-4931` |
| card/m_rdata | 639:0 | 640 | GROUND | BENIGN-UNUSED | same, `rtl/fk33_llama_top.vhd:5574` | same |
| card/m_rlast | 4:0 | 5 | GROUND | BENIGN-UNUSED | same, `rtl/fk33_llama_top.vhd:5575` | same |
| card/m_rvalid | 4:0 | 5 | GROUND | BENIGN-UNUSED | same, `rtl/fk33_llama_top.vhd:5574` | same |
| card/bst_rresp | 1:0 | 2 | GROUND | DROPPED-RESPONSE | BD never connects it (no `resp` anywhere in `jc_card_bd.tcl`); `rtl/bc_port_grant.vhd` has no resp ports (0 matches), wrapper `hw/fk33/rtl/fk33_bc_grant.vhd:24-117`; dropped by `hw/fk33/gen_pcieep.py:1984-1987` (GRANT_B list) | RECEIVER USES IT: `rtl/gdn_state_axi.vhd:454,479,532` (state store err) and NORM_HBM gain fetch `rtl/fk33_llama_top.vhd:4142`. An HBM SLVERR/DECERR is invisible |
| card/bst_bresp | 1:0 | 2 | GROUND | DROPPED-RESPONSE | as above | used at `rtl/gdn_state_axi.vhd:721,731` |
| card/kv0_rresp | 1:0 | 2 | GROUND | DROPPED-RESPONSE | as above (GRANT_CRD, `hw/fk33/gen_pcieep.py:1993`) | used at `rtl/attn_kv_axi.vhd:827` |
| card/kv1_rresp | 1:0 | 2 | GROUND | DROPPED-RESPONSE | as above | used at `rtl/attn_kv_axi.vhd:827` (slice s=1) |
| card/kv_bresp | 1:0 | 2 | GROUND | DROPPED-RESPONSE | as above (GRANT_CWR, `hw/fk33/gen_pcieep.py:1995`) | used at `rtl/attn_kv_axi.vhd:1052` |

Sum: 4+4+4+4+4+1+1+1+4+4+4+23+2+2+1+1 = 64; 5+640+5+5 = 655; 2*5 = 10; total 729.

## Notes

- **No DEFECT found.** Every grounded pin the receiver reads is grounded because its driver
  is provably constant in those bits under this build's generics, except the five
  DROPPED-RESPONSE groups, which the receivers DO read and which are therefore an
  observability gap, not a cosmetic one: B's state store, the NORM_HBM gain fetch and C's KV
  mover each raise a sticky error on non-OKAY RRESP/BRESP, and on this card that error can
  never fire.
- **Stale comment:** `hw/fk33/gen_pcieep.py:1985-1987` says the unmodelled signals (incl.
  rresp/bresp) "are handled at the HBM end by GRANT_TIES below rather than being dropped
  silently here". No `GRANT_TIES` exists anywhere in the tree (grep over *.py/*.tcl), and on
  the card side they are simply unconnected (BD 41-759 tie-off). The same applies to the FK33
  pcieep build, which shares this section.
- **A_N_JOBS = 311** is a 9B-derived constant with 5 / 9 jobs of headroom over the 27B
  per-die programs (306 / 302, from WORKLOG, not re-derived here). If a future 27B program
  exceeds 311, `job_index[8:0]` still covers up to 511 but the adapter refuses at
  `rtl/a_desc_adapter.vhd:230`; widening it past 511 would flip `job_index[9]` live and the
  allowlist below would (correctly) refuse the build until updated.
- **hw_reg/hr_reg = 0 is correct for 27B.** The seam's region ports are a constant XREG by
  construction (it only ever addresses R_X); there is no host path to any other region in the
  seam, and 27B needs none: norm gains (NORM_HBM) and B constants (B_CONST_HBM) are fetched
  from HBM.

## Open, not determined here

- Whether synthesis' constant folding is the only reason c_awlen[7:4] is NOT in the list (it
  is registered at `rtl/attn_kv_axi.vhd:1072,1109`, so its upper bits are flops, not tied nets).
  Not a problem for the check; noted so nobody expects it in the allowlist.
- 27B job counts 306/302 were taken from `docs/WORKLOG.md:121`, not recomputed.
