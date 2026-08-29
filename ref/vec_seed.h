/* ref/vec_seed.h -- ONE seeding convention for every ref/*_vec.c generator.
 *
 * THE CONVENTION, stated once so nothing has to be inferred from a call site:
 *
 *   1. The seed is the LAST optional positional argument the generator
 *      accepts.  It comes after every shape argument, so no existing caller
 *      moves and sim/regress.sh's tb_vector_args rows keep working unchanged.
 *   2. If that argument is absent or empty, the environment variable
 *      VEC_SEED is used.
 *   3. If that is absent or empty too, the generator's COMMITTED default is
 *      used, and the output is then byte-identical to the committed golden.
 *
 *   An explicit argument beats VEC_SEED; VEC_SEED beats the default.  Both
 *   accept decimal, 0x hex and 0-prefixed octal, because strtoull is called
 *   with base 0.
 *
 * WHY THE SEED IS ALWAYS PRINTED.  sim/mutate_gdn_recur.sh carried a `SEED`
 * knob that was declared, documented, advertised in its usage line, echoed
 * into its own banner -- and never passed to a generator that took no seed at
 * all.  `SEED=42` ran the committed seed and reported 42.  A knob that cannot
 * be seen to have arrived is a knob that can be inert for months.  So every
 * generator prints, on STDERR, which seed it actually used and whether that
 * was the committed default or an override.  stderr, not stdout, because
 * several of these generators write the vector file to stdout.
 *
 * WHY A ZERO SEED IS REFUSED.  Most of these generators run a 64-bit xorshift
 * (x ^= x<<13; x ^= x>>7; x ^= x<<17).  Zero is a fixed point of that map: a
 * zero seed produces an infinite run of zeros, which is not a stimulus, and it
 * would not look like an error -- it would look like a suspiciously clean
 * pass.  A seed of 0 therefore falls back to the committed default and says
 * so.  If you want a low seed, 1 works.
 *
 * WHAT A SEED SWEEP CAN AND CANNOT SEE.  Varying the seed varies the STIMULUS
 * DISTRIBUTION.  It does not vary the recipe, the shape arguments, or the
 * checks.  A defect that is present at every input, a coverage hole in the
 * SHAPE (a branch that no value of any input reaches at this ncase/DIM), and
 * an oracle that is wrong in the same way as the design are all invisible to
 * it, however many seeds are run.
 */
#ifndef VEC_SEED_H
#define VEC_SEED_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static uint64_t vec_seed(int argc, char **argv, int argi, uint64_t dflt)
{
    uint64_t s = dflt;
    const char *src = "committed default";
    const char *e;

    if (argi > 0 && argc > argi && argv[argi] && argv[argi][0]) {
        s = strtoull(argv[argi], NULL, 0);
        src = "argv";
    } else if ((e = getenv("VEC_SEED")) != NULL && e[0]) {
        s = strtoull(e, NULL, 0);
        src = "$VEC_SEED";
    }
    if (s == 0) {
        s = dflt;
        src = "committed default (a zero seed was refused: it is a fixed "
              "point of the xorshift)";
    }
    fprintf(stderr, "seed %llu  [%s]\n", (unsigned long long)s, src);
    return s;
}

/* For the one generator whose PRNG state is 32 bits (ref/attn_mac_array_vec.c).
 * Truncating a 64-bit seed can land on zero, which is the same dead fixed
 * point, so the truncation is checked rather than assumed. */
static uint32_t vec_seed32(int argc, char **argv, int argi, uint32_t dflt)
{
    uint64_t s = vec_seed(argc, argv, argi, (uint64_t)dflt);
    uint32_t t = (uint32_t)s;
    if (t == 0) {
        t = dflt;
        fprintf(stderr, "seed truncated to 32 bits was zero; using %u\n",
                (unsigned)dflt);
    }
    return t;
}

#endif /* VEC_SEED_H */
