// ref/test_rope.c
#include "fx.h"
#include <math.h>
#include <stdio.h>
static void rope_ref(float* q,int pos,int dim,int head_size){
    for(int i=0;i<dim;i+=2){int hd=i%head_size;float f=1.0f/powf(10000.0f,hd/(float)head_size);
        float val=pos*f,fcr=cosf(val),fci=sinf(val);float v0=q[i],v1=q[i+1];
        q[i]=v0*fcr-v1*fci;q[i+1]=v0*fci+v1*fcr;}
}
static void rope_fx(float* q,int pos,int dim,int head_size){
    for(int i=0;i<dim;i+=2){
        int16_t fcr=fx_cos(pos,i%head_size,head_size);
        int16_t fci=fx_sin(pos,i%head_size,head_size);
        float v0=q[i],v1=q[i+1];
        int64_t q0=llround(v0*4096.0),q1=llround(v1*4096.0);
        int64_t r0=(q0*fcr-q1*fci+(1LL<<14))>>15;
        int64_t r1=(q0*fci+q1*fcr+(1LL<<14))>>15;
        q[i]=(float)(r0/4096.0);q[i+1]=(float)(r1/4096.0);
    }
}
int main(void){
    fx_init(); fx_rope_init(512,8);
    double worst=0;
    for(int pos=0;pos<200;pos+=41){
        float a[64],b[64]; for(int j=0;j<64;j++){a[j]=b[j]=0.2f*sinf(0.5f*j)+0.05f*j;}
        rope_ref(a,pos,64,8); rope_fx(b,pos,64,8);
        for(int j=0;j<64;j++){double d=fabs(a[j]-b[j]); if(d>worst)worst=d;}
    }
    if(worst<2e-3){printf("PASS rope err=%g\n",worst);return 0;}
    printf("FAIL rope err=%g\n",worst);return 1;
}
