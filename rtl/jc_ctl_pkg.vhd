-- Jungle Cat USER3 control core: shared constants.
-- Spec: docs/superpowers/specs/2026-10-07-jc-engine-composition-design.md (S3 and the
-- second CORRECTION); plan Task 2. The slot shape (16,384 bits, header word 0, 62 payload
-- words of 256 bits, CRC-32 over bits 0..16127 at bits 16128..16159) and the FIFO tags are
-- the loader's, taken from work.jc_loader_pkg; only the control-specific values live here.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package jc_ctl_pkg is
  constant JC_CTL_MAGIC       : std_logic_vector(31 downto 0) := x"4A435431";  -- "JCT1"
  constant JC_CTL_MAGIC_STAT  : std_logic_vector(31 downto 0) := x"4A435354";  -- "JCST"
  constant JC_CTL_MAX_ITEMS   : natural := 496;   -- 32-bit items per frame (62 x 8)
  constant JC_CTL_MAX_PAYLOAD : natural := 62;    -- payload words of 256 bits
  constant JC_CTL_STATUS_BITS : natural := 384;
  constant JC_CTL_RSP_AW      : natural := 9;     -- response RAM address width (512 x 32)

  -- ops, header bits [71:64]
  constant JC_OP_NOP    : natural := 0;
  constant JC_OP_WR_INC : natural := 1;
  constant JC_OP_WR_FIX : natural := 2;
  constant JC_OP_RD_INC : natural := 3;
  constant JC_OP_RD_FIX : natural := 4;
  constant JC_OP_MEM_RD : natural := 5;

  -- header word fields
  constant JC_H_SEQ_LO    : natural := 32;  constant JC_H_SEQ_HI    : natural := 63;
  constant JC_H_OP_LO     : natural := 64;  constant JC_H_OP_HI     : natural := 71;
  constant JC_H_COUNT_LO  : natural := 72;  constant JC_H_COUNT_HI  : natural := 87;
  constant JC_H_NWORDS_LO : natural := 104; constant JC_H_NWORDS_HI : natural := 119;
  constant JC_H_ADDR_LO   : natural := 120; constant JC_H_ADDR_HI   : natural := 183;

  -- status word fields (TDO bits 0..383). The executor (Task 3) drives the fields marked
  -- EXEC; the frame core overwrites the fields marked CORE with its own values.
  constant JC_S_MAGIC_HI    : natural := 31;                                   -- CORE
  constant JC_S_DONE_LO     : natural := 32;  constant JC_S_DONE_HI    : natural := 63;  -- EXEC
  constant JC_S_RSPSEQ_LO   : natural := 64;  constant JC_S_RSPSEQ_HI  : natural := 95;  -- EXEC
  constant JC_S_RSPCNT_LO   : natural := 96;  constant JC_S_RSPCNT_HI  : natural := 111; -- EXEC
  constant JC_S_RSPVALID    : natural := 112; -- EXEC; the core masks it on a stale status
  constant JC_S_AXIERR      : natural := 113;                                  -- EXEC
  constant JC_S_AXIRESP_LO  : natural := 114; constant JC_S_AXIRESP_HI : natural := 115; -- EXEC
  constant JC_S_ERRSEQ_LO   : natural := 116; constant JC_S_ERRSEQ_HI  : natural := 147; -- EXEC
  constant JC_S_DESYNC_LO   : natural := 148; constant JC_S_DESYNC_HI  : natural := 163; -- CORE
  constant JC_S_OVF         : natural := 164;                                  -- CORE
  constant JC_S_CRCF_LO     : natural := 165; constant JC_S_CRCF_HI    : natural := 180; -- CORE
  -- [383:181] zero by convention (the executor ties them low; the core passes them through)
end package;
