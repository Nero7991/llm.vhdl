/* rmsnorm_bf_vec_n5120 -- ref/rmsnorm_bf_vec.c at the Qwen3.8-27B hidden size.
 *
 * WHY A SEPARATE GENERATOR AND NOT A ROW.  sim/regress.sh maps a vector file
 * to its generator by stem (sim/X.txt <- ref/X.c) and keys a testbench by
 * name, so one generator cannot feed two benches at two shapes.  This file
 * is the same generator, #included verbatim, with its shape pinned here:
 * N = 5120 (SHAPE.hidden at 27B, NOT a power of two), 40 cases (one full
 * period of make_case's 40 structured/random selectors), Q 12, eps 1e-6.
 * It is the golden for sim/tb_rmsnorm_bf_mem_vec.vhd.
 *
 * WHY 5120 MATTERS.  docs/debugging/2026-10-09_jc-27b-first-token-residual-
 * gain.md: rtl/rmsnorm_bf_mem.vhd took the mean as S >> clog2(N), which at
 * 5120 divides by 8192 and makes every hidden-length norm sqrt(1.6) = 1.2649x
 * too large on the card.  The power-of-two rows (N = 128, 4096) cannot see it.
 *
 * Usage: ./rmsnorm_bf_vec_n5120 [out.txt] [seed]
 */
#define main rmsnorm_bf_vec_main
#include "rmsnorm_bf_vec.c"
#undef main

int main(int argc, char **argv)
{
    char *av[7];
    av[0] = argv[0];
    av[1] = (argc > 1) ? argv[1] : "rmsnorm_bf_vec_n5120.txt";
    av[2] = "40";
    av[3] = "5120";
    av[4] = (argc > 2) ? argv[2] : "20261009";
    av[5] = "12";
    av[6] = "1e-6";
    return rmsnorm_bf_vec_main(7, av);
}
