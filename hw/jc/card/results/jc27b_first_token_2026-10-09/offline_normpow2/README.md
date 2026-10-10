# Offline localisation of the 27B residual gain (2026-10-09, no hardware)

Cause: `rtl/rmsnorm_bf_mem.vhd` divides the sum of squares by `2^clog2(N)` (a shift). At the
27B hidden size N = 5120 that is 8192, so every attn_norm / post_attention_norm / output_norm
output is `sqrt(8192/5120) = 1.2649x` too large. Full write-up:
`docs/debugging/2026-10-09_jc-27b-first-token-residual-gain.md`, section "2026-10-09 addendum".

Reference: `ref/run9b.c` built with `-DREF27B` (commit 20862d03), bfp mode (the card's own
INT4 bytes, bit-exact A jobs, float between them). `--norm-pow2` models the RTL's divisor.
Working dirs (symlinks + `tools/ref9b/make_index.py` index) were under
`~/regress_scratch/jc27b_gain/work/`.

| file | what |
|---|---|
| `cmp_all.txt` | token 0: ok model, pow2 model, card rows, llama.cpp, all pairings |
| `cmp_23.txt` | 23-token prompt, positions 0 / 3 / 22, both dies |
| `r23B_*.log` | the 23-token runs' top-10 at position 22 |
| `run*.log`, `x*.txt` | the token-0 runs and their R_X outputs (`exp E` + int16) |
| `ghdl_rmsnorm_bf_mem_N5120.txt` | GHDL: the unit's own assert fails at N = 5120 (empty at 4096) |
| `check_image_consts_27b.txt` | every image constant vs the GGUF, and the --perturb teeth run |
| `run23.sh`, `cmp3.py` | the commands |
