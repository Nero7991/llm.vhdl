/* ref/test_softmax.c — Task 5: unit test for softmax_fx using fx_exp_q (Q12).
 * Compare softmax_fx against the float reference on a fixed 40-element vector.
 * PASS: max abs error < 2e-3 and sum within 1e-3 of 1.0.
 */
#include "fx.h"
#include <math.h>
#include <stdio.h>

static void softmax_ref(float* x, int n) {
    float m = x[0];
    for (int i = 1; i < n; i++) if (x[i] > m) m = x[i];
    float s = 0;
    for (int i = 0; i < n; i++) { x[i] = expf(x[i] - m); s += x[i]; }
    for (int i = 0; i < n; i++) x[i] /= s;
}

static void softmax_fx(float* x, int n) {
    /* Find max (float ok; z = x[i]-max is always <= 0). */
    float max_val = x[0];
    for (int i = 1; i < n; i++) if (x[i] > max_val) max_val = x[i];

    /* Compute Q12 exp for each element and accumulate integer sum. */
    int32_t e_arr[n];
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        float z = x[i] - max_val;
        int32_t z_q = (int32_t)lroundf(z * 4096.0f);
        e_arr[i] = fx_exp_q(z_q, 12);
        sum += e_arr[i];
    }
    if (sum == 0) sum = 1;  /* guard: can only happen if all inputs << -16 */

    /* Normalize: probability = e_i / sum (Q12 scale cancels). */
    for (int i = 0; i < n; i++) {
        x[i] = (float)e_arr[i] / (float)sum;
    }
}

int main(void) {
    fx_init();
    float a[40], b[40];
    for (int i = 0; i < 40; i++) {
        a[i] = b[i] = 0.5f * sinf(0.9f * i) + (i == 7 ? 6.0f : 0.0f);
    }
    softmax_ref(a, 40);
    softmax_fx(b, 40);
    double e = 0, s = 0;
    for (int i = 0; i < 40; i++) {
        double d = fabs(a[i] - b[i]);
        if (d > e) e = d;
        s += b[i];
    }
    if (e < 2e-3 && fabs(s - 1.0) < 1e-3) {
        printf("PASS softmax err=%g sum=%g\n", e, s);
        return 0;
    }
    printf("FAIL softmax err=%g sum=%g\n", e, s);
    return 1;
}
