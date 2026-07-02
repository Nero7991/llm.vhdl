// ref/test_rmsnorm.c
#include "fx.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
static void rmsnorm_ref(float* o, float* x, float* w, int n){
    float ss=0; for(int j=0;j<n;j++) ss+=x[j]*x[j]; ss/=n; ss+=1e-5f; ss=1.0f/sqrtf(ss);
    for(int j=0;j<n;j++) o[j]=w[j]*(ss*x[j]);
}
/* Identical body to the rmsnorm_fx added to run_fx.c: */
static void rmsnorm_fx(float* o, const float* x, const float* w, int n) {
    enum { RQ = 12 };
    int16_t xm[n];
    int xe = fx_bfp_from_float(xm, x, n);

    /* S = sum(xm[j]^2) ≈ sum(x_j^2) * 2^(2*xe) */
    int64_t S = 0;
    for (int j = 0; j < n; j++) S += (int64_t)xm[j] * xm[j];

    /* mean_sq_q = round(mean_sq * 2^RQ) where mean_sq = S / (n * 2^(2*xe)) */
    int64_t num = S << RQ;                      /* S * 2^RQ; fits int64 for n<=8192 */
    int64_t mean_sq_q = (num + (int64_t)n / 2) / (int64_t)n;  /* rounded /n */
    if (xe >= 0) {
        int sh = 2 * xe; if (sh > 62) sh = 62;
        if (sh > 0) mean_sq_q = (mean_sq_q + (1LL << (sh - 1))) >> sh;  /* rounded >>sh */
    } else {
        int sh = -2 * xe; if (sh > 62) sh = 62;
        mean_sq_q <<= sh;
    }
    mean_sq_q += (int64_t)llround(1e-5 * (1 << RQ));  /* eps in Qq; = 0 at RQ=12 */
    if (mean_sq_q < 1) mean_sq_q = 1;

    int32_t inv = fx_rsqrt(mean_sq_q, RQ);
    float inv_f = (float)inv / (float)(1 << RQ);
    for (int j = 0; j < n; j++) o[j] = w[j] * inv_f * x[j];
}
int main(void){
    fx_init();
    float x[64], w[64], a[64], b[64];
    for(int j=0;j<64;j++){ x[j]=0.3f*sinf(0.7f*j)-0.1f*j*0.01f; w[j]=1.0f+0.05f*cosf(0.3f*j); }
    rmsnorm_ref(a,x,w,64); rmsnorm_fx(b,x,w,64);
    double e=0; for(int j=0;j<64;j++){ double d=fabs(a[j]-b[j]); if(d>e)e=d; }
    if(e<2e-3){ printf("PASS rmsnorm err=%g\n",e); return 0; }
    printf("FAIL rmsnorm err=%g\n",e); return 1;
}
