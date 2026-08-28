/* ref/seq_vec_chain_vec.c -- the INDEPENDENT ORACLE FOR SUBSYSTEM D's D-VEC
 * ISSUE SEAM: `seq_desc_fetch` -> `seq_opdec` -> `seq_region_lock` ->
 * `seq_vec_issue` -> `seq_vec_res`, and back again.
 *
 * ======================================================================
 * WHAT A SEAM ORACLE HAS TO CERTIFY, AND WHY IT IS NOT THE UNIT ORACLE
 * ======================================================================
 * `ref/seq_vec_res_vec.c` already certifies ONE residual: given n, ex, ee and
 * two mantissa vectors it pins every bit of the output and its exponent, over
 * six oracles that share no arithmetic with the RTL.  It says nothing at all
 * about where n, ex and ee CAME FROM, and that is the entire content of the
 * seam.  At the seam the questions are:
 *
 *   - is `i_n` the descriptor's `n_rows` for THIS step, or the previous one's?
 *   - is `i_exp_x` the exponent the region lock holds for the descriptor's
 *     `src`, and `i_exp_e` the one it holds for `src2` -- or are they swapped,
 *     or both read from one region, or read one state too late?
 *   - does the unit's `o_exp` get back through the adapter, through
 *     `seq_opdec`'s capture, into the lock's exponent file for the DESTINATION
 *     region -- so that the NEXT step that reads that region sees it?
 *
 * The third is what makes a CHAIN the right shape for the oracle rather than a
 * bag of independent cases.  The residual is IN PLACE: it reads X, writes X,
 * and publishes X's new exponent.  So the output of step k is the input of
 * step k+1, and a single lost, stale, swapped or misrouted exponent does not
 * produce a locally wrong answer that a per-step comparison might rescale
 * away -- it desynchronises every remaining step of the token.  A bag of
 * independent cases with the exponents handed in by the testbench cannot test
 * the feedback path at all, because the testbench IS the feedback path.
 *
 * ======================================================================
 * THE DOUBLE ORACLE, STATED HONESTLY
 * ======================================================================
 * This file shares no state machine, no handshake and no control flow with any
 * RTL.  It is a straight sequential loop over the steps with one array of
 * per-region exponents, which is the specification of the seam and not a model
 * of the implementation.
 *
 * It DOES share `recipe()` with `ref/seq_vec_res_vec.c`, by including that
 * file as a library.  That is deliberate and is not a shared-machinery
 * violation: `recipe()` is the reference for the arithmetic, it is mutation
 * tested in its own right, and the RTL it is being compared against is
 * `rtl/seq_vec_res.vhd`, which shares nothing with it.  Sharing it the other
 * way -- writing the chain's arithmetic a second time -- would give two
 * references that can disagree with each other, which is worse than one.
 * A mutation of `seq_vec_res_vec.c` mutates BOTH programs, which is the
 * property that makes `sim/mutate_ref_seq_vec_res.sh` still meaningful.
 *
 * WHAT THIS ORACLE CANNOT CERTIFY, and it is worth saying so up front: the
 * ARBITRATION.  Whether `u_ready` falls at the right instant, whether a start
 * is accepted while a completion is held, whether `done` survives an ack tied
 * high -- none of that is a function of the input data, so no data-driven
 * oracle can see it.  Those are covered by counting identities and protocol
 * guards in `sim/tb_seq_vec_seam.vhd`, which is a weaker instrument, and the
 * mutation table in the debugging note says which mutations only those catch.
 *
 * ======================================================================
 * THE CHAIN ORACLES.  Neither restates the recipe.
 * ======================================================================
 *  C1  THE RUNNING SUM, EXACTLY, IN INTEGERS.  The value that the pair
 *      (mantissas, exponent) represents after step k must equal the exact real
 *      sum X0 + E_0 + ... + E_k to within a bound DERIVED from the recipe's
 *      rounding rules and ACCUMULATED across the chain.  Everything is a
 *      dyadic rational, so it is carried as a __int128 at a common grid and
 *      compared with `<=` -- no floating point and no tolerance.  This is the
 *      oracle that a swapped exponent, a stale exponent, a lost feedback or a
 *      wrong n dies on, and it does so with an error that GROWS along the
 *      chain rather than a single wrong element.
 *  C2  WHOLE-CHAIN EXPONENT-SHIFT INVARIANCE.  Add the same K to the initial
 *      exponent AND to every ER exponent: every mantissa of every step must be
 *      bit-identical and every published exponent must move by exactly K.  The
 *      per-step O4 says one step depends only on the DIFFERENCE of its two
 *      exponents; C2 says the CHAIN does, which is a different statement once
 *      the output exponent feeds the next input.
 *  C3  THE CHAIN IS NOT DEGENERATE.  Coverage is printed on every run and a
 *      zero in any column fails the generator: a chain in which every step has
 *      sh = 0, or in which the exponent never moves, would let a completely
 *      broken feedback path pass C1 by accident.  A guard whose subject is a
 *      constant is a comment.
 *
 * Build: cc -O2 -Wall -Wextra -o seq_vec_chain_vec seq_vec_chain_vec.c -lm
 * Usage: ./seq_vec_chain_vec <out.txt> [n] [nres] [seed]
 */
#define SEQ_VEC_RES_AS_LIB
#include "seq_vec_res_vec.c"

#define NRES_MAX 64

/* The chain, as data.  Deliberately flat: one array per quantity, indexed by
 * step, so that reading this file tells you what the seam is supposed to
 * produce without following any control flow. */
static int16_t  X0v[NMAX];
static int16_t  Ev[NRES_MAX][NMAX];
static int16_t  Xv[NRES_MAX][NMAX];
static int      eev[NRES_MAX], oexpv[NRES_MAX], shv[NRES_MAX], satv[NRES_MAX];
static int      qv[NRES_MAX], exv[NRES_MAX];

static int cfail = 0;
static void cbad(int k, const char *what, int i, long long got, long long want)
{
    fprintf(stderr, "CHAIN ORACLE FAIL (%s) step %d elem %d: got %lld want %lld\n",
            what, k, i, got, want);
    cfail++;
}

/* Run the whole chain.  `dst` receives every step's output; the per-step
 * oracles of seq_vec_res_vec.c run on every step unless `quiet`. */
static void run_chain(int n, int nres, int ex0, int shift, int quiet)
{
    static job_t j;
    int ex = ex0 + shift;
    for (int k = 0; k < nres; k++) {
        memset(&j, 0, sizeof j);
        j.n  = n;
        j.ex = ex;
        j.ee = eev[k] + shift;
        for (int i = 0; i < n; i++) {
            j.x[i] = (k == 0) ? X0v[i] : Xv[k-1][i];
            j.e[i] = Ev[k][i];
        }
        recipe(&j);
        if (!quiet) {
            oracle_real(&j);
            oracle_range(&j);
            oracle_wide(&j);
            oracle_clamp(&j);
            oracle_round_dir(&j);
            oracle_shift_invariant(&j);
        }
        if (shift == 0) {
            for (int i = 0; i < n; i++) Xv[k][i] = j.out[i];
            oexpv[k] = j.oexp; shv[k] = j.sh; satv[k] = j.sat;
            qv[k] = j.q; exv[k] = ex;
        } else {
            /* C2: the shifted run must reproduce the unshifted one exactly. */
            for (int i = 0; i < n; i++)
                if (j.out[i] != Xv[k][i])
                    { cbad(k, "C2 mantissa not chain-shift-invariant", i,
                           j.out[i], Xv[k][i]); return; }
            if (j.oexp != oexpv[k] + shift)
                cbad(k, "C2 exponent did not move by K", -1,
                     j.oexp, oexpv[k] + shift);
        }
        ex = j.oexp;
    }
}

/* C1.  Exact running sum at a common dyadic grid, in __int128, with a bound
 * derived from the recipe's own rounding rules and accumulated step by step.
 * NOTHING here re-derives an output: it only says what a running sum is. */
static void oracle_chain_sum(int n, int nres, int ex0)
{
    int hi = ex0, lo = ex0;
    for (int k = 0; k < nres; k++) {
        int e[3]; e[0] = eev[k]; e[1] = oexpv[k]; e[2] = qv[k];
        for (int t = 0; t < 3; t++) { if (e[t] > hi) hi = e[t];
                                      if (e[t] < lo) lo = e[t]; }
    }
    int GB = hi + 2;                       /* every shift below is >= 0 */
    if (GB - lo > 60) {
        fprintf(stderr, "seq_vec_chain_vec: exponent span %d exceeds the exact "
                "grid; C1 cannot be evaluated\n", GB - lo);
        cfail++;
        return;
    }

    static __int128 exact[NMAX];
    for (int i = 0; i < n; i++)
        exact[i] = (__int128)X0v[i] << (GB - ex0);

    __int128 bound = 0;
    int ex = ex0;
    for (int k = 0; k < nres; k++) {
        for (int i = 0; i < n; i++)
            exact[i] += (__int128)Ev[k][i] << (GB - eev[k]);

        /* Half an LSB at the accumulator grid for each operand that had to be
         * shifted DOWN to reach it; a left shift is exact and contributes
         * nothing.  Half an LSB at the output grid for the requantise, and
         * nothing at all when sh = 0, where the recipe is exact by
         * construction.  One whole output LSB where the saturating clamp
         * fired, which the contract bounds at exactly one. */
        if (qv[k] < ex)      bound += (__int128)1 << (GB - qv[k] - 1);
        if (qv[k] < eev[k])  bound += (__int128)1 << (GB - qv[k] - 1);
        if (shv[k] > 0)      bound += (__int128)1 << (GB - oexpv[k] - 1);
        if (satv[k])         bound += (__int128)1 << (GB - oexpv[k]);

        for (int i = 0; i < n; i++) {
            __int128 got = (__int128)Xv[k][i] << (GB - oexpv[k]);
            __int128 d   = got - exact[i];
            if (d < 0) d = -d;
            if (d > bound) {
                /* Printed at the OUTPUT grid so the number is readable; the
                 * comparison above is exact and at the fine grid. */
                cbad(k, "C1 chain value outside the accumulated bound", i,
                     (long long)(d >> (GB - oexpv[k])),
                     (long long)(bound >> (GB - oexpv[k])));
                return;
            }
        }
        ex = oexpv[k];
    }
}

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "seq_vec_chain_vec.txt";
    int n    = argc > 2 ? atoi(argv[2]) : 250;
    int nres = argc > 3 ? atoi(argv[3]) : 8;
    rs = (uint64_t)(argc > 4 ? atoi(argv[4]) : 20260827) * 2654435761u + 1;

    if (n < 1 || n > NMAX || nres < 1 || nres > NRES_MAX) {
        fprintf(stderr, "seq_vec_chain_vec: n in 1..%d, nres in 1..%d\n",
                NMAX, NRES_MAX);
        return 2;
    }

    const int ex0 = 12;

    /* ---- step 0 is CRAFTED to make the saturating clamp reachable.  With the
     * output shift driven by the maximum, |round(acc, sh)| <= 2^15 always and
     * the only value that reaches 2^15 is a maximum of exactly 2^(p+1) - 1.
     * Random mantissas essentially never land there -- the per-op reference
     * records that 24 random cases covered the clamp zero times -- and in a
     * CHAIN it is worse, because after step 0 neither operand is under the
     * generator's control any more.  So it is placed first, where X is still
     * ours: q = 12, sx = 0, se = 1, acc = 32767 + 2*16384 = 65535, p = 15,
     * sh = 1, round_half_up(65535,1) = 32768 -> clamps. --------------------*/
    for (int i = 0; i < n; i++) X0v[i] = 0;
    X0v[3 % n] = 32767;

    /* ---- the ER exponents.  Chosen RELATIVE to a fixed schedule rather than
     * randomly, because the properties that have to be covered are properties
     * of ee - ex and a random draw leaves the SHMAX clamp and the two shift
     * directions to luck.  The list is walked cyclically. -------------------*/
    static const int DELTA[] = { -1, +3, -5, +(SHMAX+1), 0, -(SHMAX+2), +7, -2 };
    const int NDELTA = (int)(sizeof DELTA / sizeof DELTA[0]);
    static int dlt[NRES_MAX];

    for (int k = 0; k < nres; k++) {
        if (k == 0) {
            for (int i = 0; i < n; i++) Ev[k][i] = 0;
            Ev[k][3 % n] = 16384;
            dlt[k] = -1;
        } else if (k == 1) {
            /* STEP 1 IS CRAFTED TOO, for sh = 0 -- the case in which the
             * recipe is EXACT and C1's bound therefore does not grow at all.
             * It is no more reachable by luck than the saturating clamp is: a
             * requantised X has its maximum in [2^KEEP, 2^15), so a step whose
             * other operand is comparable pushes p to 15 and sh to 1 every
             * time.  It needs an ER that is SMALL and at the SAME grid, and
             * after step 0 that combination never occurs by chance. */
            for (int i = 0; i < n; i++) Ev[k][i] = rnd_mant(1);
            /* Step 0 SATURATES, so X leaves it with its maximum at exactly
             * 32767, whose msb_pos is 14 -- one below the binade.  Adding a
             * random small ER to that is a COIN FLIP: a positive draw at the
             * maximum's index pushes p back to 15 and sh to 1, a negative one
             * leaves p at 14 and sh at 0.  Pinning the sign is the difference
             * between covering sh = 0 half the time and covering it always,
             * and a coverage column that depends on the seed is not a column. */
            Ev[k][3 % n] = -8192;
            dlt[k] = 0;
        } else {
            /* Alternate a small-magnitude mode with a full-range one, so the
             * chain contains both steps where the requantise is exact and
             * steps where it is not. */
            for (int i = 0; i < n; i++) Ev[k][i] = rnd_mant((k % 3 == 0) ? 1 : 3);
            dlt[k] = DELTA[k % NDELTA];
        }
        eev[k] = ex0 + dlt[k];      /* re-aimed below from the real chain */
    }

    /* The deltas are RELATIVE to each step's input exponent, which is the
     * previous step's output and is therefore not known until the chain has
     * been run.  Run it, re-aim, run it again.  A schedule aimed at a guessed
     * exponent covers whatever it happens to hit, which is how a coverage
     * column silently becomes a constant. */
    for (int pass = 0; pass < 3; pass++) {
        run_chain(n, nres, ex0, 0, 1);
        for (int k = 1; k < nres; k++) eev[k] = exv[k] + dlt[k];
    }
    run_chain(n, nres, ex0, 0, 1);

    /* The scored run: every per-step oracle, then the chain oracles. */
    run_chain(n, nres, ex0, 0, 0);
    oracle_chain_sum(n, nres, ex0);
    /* C2, at two shifts and in both directions. */
    run_chain(n, nres, ex0, +9, 1);
    run_chain(n, nres, ex0, -6, 1);

    if (nfail || cfail) {
        fprintf(stderr, "seq_vec_chain_vec: %d per-step and %d chain ORACLE "
                "FAILURES\n", nfail, cfail);
        return 1;
    }

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 2; }
    fprintf(f, "%d %d %d %d %d %d %d\n", n, nres, ex0, MANT_W, ACC_W, SHMAX, KEEP);
    for (int i = 0; i < n; i++) fprintf(f, "%d ", X0v[i]);
    fputc('\n', f);
    for (int k = 0; k < nres; k++) {
        fprintf(f, "%d %d %d %d %d\n", k, eev[k], oexpv[k], shv[k], satv[k]);
        for (int i = 0; i < n; i++) fprintf(f, "%d ", Ev[k][i]);
        fputc('\n', f);
        for (int i = 0; i < n; i++) fprintf(f, "%d ", Xv[k][i]);
        fputc('\n', f);
    }
    fclose(f);

    /* ---- C3.  COVERAGE, printed every run.  A zero column is a hole and the
     * generator FAILS on it: the seam's whole point is that the exponent moves
     * between steps, and a chain in which it never moves would let a broken
     * feedback path pass C1 by accident. ----------------------------------- */
    int cov_sh0 = 0, cov_shpos = 0, cov_sat = 0, cov_clamp = 0;
    int cov_up = 0, cov_dn = 0, cov_moved = 0;
    for (int k = 0; k < nres; k++) {
        cov_sh0   += (shv[k] == 0);
        cov_shpos += (shv[k] >  0);
        cov_sat   += (satv[k] != 0);
        cov_clamp += ((exv[k] > eev[k] ? exv[k] : eev[k]) != qv[k]);
        cov_up    += (eev[k] > exv[k]);
        cov_dn    += (eev[k] < exv[k]);
        cov_moved += (oexpv[k] != exv[k]);
    }
    fprintf(stderr, "seq_vec_chain_vec: n=%d, %d chained residual steps, "
            "6 per-step oracles + C1 + C2 clean\n", n, nres);
    fprintf(stderr, "  coverage: sh=0 %d | sh>0 %d | saturating clamp %d | "
            "SHMAX clamp %d | ee above ex %d | ee below ex %d | "
            "output exponent moved %d | n not a multiple of 16 %d\n",
            cov_sh0, cov_shpos, cov_sat, cov_clamp, cov_up, cov_dn, cov_moved,
            (n % 16) != 0);
    if (!cov_sh0 || !cov_shpos || !cov_sat || !cov_clamp || !cov_up || !cov_dn
        || !cov_moved) {
        fprintf(stderr, "seq_vec_chain_vec: COVERAGE HOLE -- a property above "
                "is reached by no step, so nothing tests it\n");
        return 1;
    }
    return 0;
}
