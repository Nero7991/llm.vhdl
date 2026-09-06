-- sim/tb_shape_mirror.vhd -- do the Python and VHDL `mk_shape_scaled` agree?
--
-- `tools/gen_layer_program.py` carries a hand transcription of
-- `rtl/llama_map_pkg.vhd`'s `mk_shape_scaled`, and until today NOTHING
-- compared the two.  The one comparison that existed was a table written by
-- hand into a comment in the VHDL, and it went stale: it warned that the
-- Python "emits a plan with TWO ZERO-SIZED REGIONS instead of refusing" when
-- that had been fixed 36 minutes after the comment was written.
--
-- The divergence stopped being academic when subsystem C's route to HBM was
-- traced.  NOT because the card is blocked -- the card takes
-- `mk_shape(MODEL, NCARDS)` and the real Qwen3.5-9B is attn_head_dim 256,
-- which already satisfies every `C_KV_AXI` constraint -- but because the KV
-- cache is entirely UNCOVERED in simulation: `attn_kv_axi` cannot elaborate
-- at the ATTN_HD 16 the benches run at, and attn_hd 64 is the smallest shape
-- that could cover it.  So the `attn_hd > 32` branch, the one the Python did
-- not have, is what a future C_KV_AXI bench stands on.
--
-- NEITHER SIDE IS THE ORACLE.  These are two transcriptions of one
-- specification.  A failure here says they disagree; it does not say which is
-- right, and the report deliberately prints both values so the reader decides.
library ieee;
use ieee.std_logic_1164.all;
use work.llama_map_pkg.all;
use work.shape_mirror_pkg.all;

entity tb_shape_mirror is end entity;

architecture sim of tb_shape_mirror is
  function name_of(i : natural) return string is
  begin
    case i is
      when  0 => return "attn_head_dim"; when  1 => return "blocks";
      when  2 => return "attn_interval"; when  3 => return "hidden";
      when  4 => return "ffn";           when  5 => return "key_heads";
      when  6 => return "val_heads";     when  7 => return "head_dim";
      when  8 => return "attn_q_heads";  when  9 => return "attn_kv_heads";
      when 10 => return "vocab_shard";   when 11 => return "key_dim";
      when 12 => return "val_dim";       when 13 => return "qkv_dim";
      when 14 => return "att_q";         when 15 => return "att_qg";
      when 16 => return "att_kv";        when 17 => return "region_max";
      when others => return "?";
    end case;
  end function;
begin
  main : process is
    variable s    : shape_t;
    variable vhdl : integer;
    variable chk, bad : natural := 0;
    variable hd : integer;
  begin
    for r in 0 to N_ROW-1 loop
      hd := PY_MIRROR(r, 0);
      s  := mk_shape_scaled(BLOCKS_C, ATTN_INT_C, hd);
      for f in 0 to N_FIELD-1 loop
        case f is
          when  0 => vhdl := s.attn_head_dim;
          when  1 => vhdl := s.blocks;
          when  2 => vhdl := s.attn_interval;
          when  3 => vhdl := s.hidden;
          when  4 => vhdl := s.ffn;
          when  5 => vhdl := s.key_heads;
          when  6 => vhdl := s.val_heads;
          when  7 => vhdl := s.head_dim;
          when  8 => vhdl := s.attn_q_heads;
          when  9 => vhdl := s.attn_kv_heads;
          when 10 => vhdl := s.vocab_shard;
          when 11 => vhdl := key_dim(s);
          when 12 => vhdl := val_dim(s);
          when 13 => vhdl := qkv_dim(s);
          when 14 => vhdl := att_q(s);
          when 15 => vhdl := att_qg(s);
          when 16 => vhdl := att_kv(s);
          when others => vhdl := region_max(s);
        end case;
        chk := chk + 1;
        if vhdl /= PY_MIRROR(r, f) then
          bad := bad + 1;
          report "MIRROR DIVERGENCE at attn_hd=" & integer'image(hd)
               & " field " & name_of(f)
               & ": vhdl=" & integer'image(vhdl)
               & " python=" & integer'image(PY_MIRROR(r, f))
               & " -- neither side is the oracle; decide which is right"
            severity error;
        end if;
      end loop;
    end loop;

    -- A mirror that compares nothing passes vacuously.  18 fields x 3 shapes.
    if chk /= N_ROW * N_FIELD then
      bad := bad + 1;
      report "the bench did not compare every field: chk="
           & integer'image(chk) severity error;
    end if;

    if bad = 0 then
      report "tb_shape_mirror RESULT: PASS -- checks=" & integer'image(chk)
           & " divergences=0 over attn_hd 16, 32 and 64";
    else
      report "tb_shape_mirror RESULT: FAIL -- checks=" & integer'image(chk)
           & " divergences=" & integer'image(bad);
    end if;
    wait;
  end process;
end architecture;
