/* ref/test_swiglu.c — Task 5: unit test for swiglu_fx using fx_sigmoid_q (Q12).
 * Compare fixed-point silu(v)*hb2 against float reference on a 172-element vector.
 * PASS: max abs error < 3e-3.
 */
#include "fx.h"
#include <math.h>
#include <stdio.h>

static void swiglu_fx(float* hb, const float* hb2, int n) {
    /* SiLU(v) * w3: v*sigmoid(v)*hb2, all in Q12 fixed point. */
    for (int i = 0; i < n; i++) {
        int32_t v_q  = (int32_t)lroundf(hb[i]  * 4096.0f);
        int32_t h2_q = (int32_t)lroundf(hb2[i] * 4096.0f);
        int32_t sig  = fx_sigmoid_q(v_q, 12);                /* Q12, in [0,1] */
        int64_t silu_q = ((int64_t)v_q * sig) >> 12;         /* silu=v*sig, Q12 */
        int64_t out_q  = (silu_q * h2_q) >> 12;              /* *hb2, Q12 */
        hb[i] = (float)out_q / 4096.0f;
    }
}

int main(void) {
    fx_init();
    float hb[172], hb2[172], ref[172];
    for (int i = 0; i < 172; i++) {
        hb[i]  = 0.8f * sinf(0.4f * i);
        hb2[i] = 0.5f * cosf(0.2f * i);
        float v = hb[i];
        v *= 1.0f / (1.0f + expf(-v));
        ref[i] = v * hb2[i];
    }
    swiglu_fx(hb, hb2, 172);
    double e = 0;
    for (int i = 0; i < 172; i++) {
        double d = fabs(hb[i] - ref[i]);
        if (d > e) e = d;
    }
    if (e < 3e-3) {
        printf("PASS swiglu err=%g\n", e);
        return 0;
    }
    printf("FAIL swiglu err=%g\n", e);
    return 1;
}
