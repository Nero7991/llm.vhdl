// ref/test_fx.c  — unit tests for fx.h primitives
#include "fx.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int fails = 0;
#define CHECK(name, cond, got, want) do { \
    if (cond) { printf("PASS %s\n", name); } \
    else { printf("FAIL %s got=%g want=%g\n", name, (double)(got), (double)(want)); fails++; } \
} while (0)

int main(void) {
    fx_init();

    // 1. block-fp round-trip: quantize a vector, reconstruct, compare.
    {
        float x[8] = {0.0f, 1.5f, -2.25f, 0.001f, 12.0f, -0.5f, 3.14159f, -11.9f};
        int16_t m[8]; int e = fx_bfp_from_float(m, x, 8);
        double maxerr = 0;
        for (int j = 0; j < 8; j++) { double d = fabs(fx_bfp_get(m, e, j) - x[j]); if (d > maxerr) maxerr = d; }
        // resolution is 2^-e; largest element ~12 -> e ~ 11 -> res ~ 5e-4
        CHECK("bfp_roundtrip", maxerr < 1e-3, maxerr, 0.0);
    }

    // 2. fx_make_scale + fx_scale_mul reproduce a float scale on a known accumulator.
    {
        float scale = 0.0123456f; int32_t mult; int shift; fx_make_scale(scale, &mult, &shift);
        int64_t acc = 1000000; int32_t r = fx_scale_mul(acc, mult, shift);
        double want = acc * (double)scale;
        CHECK("scale_mul", fabs(r - want) < 2.0, r, want);
    }

    // 3. rsqrt over a decade, Q12.
    {
        int q = 12; double worst = 0;
        for (double v = 0.05; v < 8.0; v *= 1.7) {
            int64_t in = (int64_t)llround(v * (1 << q));
            int32_t out = fx_rsqrt(in, q);
            double got = out / (double)(1 << q), want = 1.0 / sqrt(v);
            double rel = fabs(got - want) / want; if (rel > worst) worst = rel;
        }
        CHECK("rsqrt", worst < 0.005, worst, 0.0);
    }

    // 4. exp for z<=0, Q12.
    {
        int q = 12; double worst = 0;
        for (double z = 0.0; z >= -15.0; z -= 0.3) {
            int32_t in = (int32_t)lround(z * (1 << q));
            int32_t out = fx_exp_q(in, q);
            double got = out / (double)(1 << q), want = exp(z);
            double d = fabs(got - want); if (d > worst) worst = d;
        }
        CHECK("exp", worst < 0.005, worst, 0.0);
    }

    // 5. sigmoid, Q12.
    {
        int q = 12; double worst = 0;
        for (double z = -15; z <= 15; z += 0.25) {
            int32_t in = (int32_t)lround(z * (1 << q));
            int32_t out = fx_sigmoid_q(in, q);
            double got = out / (double)(1 << q), want = 1.0 / (1.0 + exp(-z));
            double d = fabs(got - want); if (d > worst) worst = d;
        }
        CHECK("sigmoid", worst < 0.005, worst, 0.0);
    }

    // 6. RoPE tables: Q1.15 cos/sin match, head_size=8, seq_len=512.
    {
        fx_rope_init(512, 8); double worst = 0;
        for (int pos = 0; pos < 512; pos += 37) {
            for (int i = 0; i < 8; i += 2) {
                double freq = 1.0 / pow(10000.0, (i % 8) / 8.0), val = pos * freq;
                double c = fx_cos(pos, i, 8) / 32768.0, s = fx_sin(pos, i, 8) / 32768.0;
                double dc = fabs(c - cos(val)), ds = fabs(s - sin(val));
                if (dc > worst) worst = dc; if (ds > worst) worst = ds;
            }
        }
        CHECK("rope_tables", worst < 1e-3, worst, 0.0);
    }

    if (fails) { printf("%d FAILED\n", fails); return 1; }
    printf("ALL PASS\n"); return 0;
}
