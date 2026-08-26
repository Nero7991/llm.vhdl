/* ref/dump_luts.c — dump fx.h LUTs and kernel I/O goldens for the VHDL ROMs. */
#include "fx.h"
#include <stdio.h>
static void dump_arr(const char* path, const int64_t* a, int n){
    FILE* f=fopen(path,"w"); if(!f){perror(path);exit(1);}
    for(int i=0;i<n;i++) fprintf(f,"%lld\n",(long long)a[i]);
    fclose(f);
}
int main(void){
    fx_init(); fx_rope_init(512, 8);
    dump_arr("mem/luts/rsqrt_seed.mem", _fx_rsqrt_seed, 64);
    dump_arr("mem/luts/exp_lut.mem",    _fx_exp_lut_q, 257);
    dump_arr("mem/luts/sig_lut.mem",    _fx_sig_lut_q, 513);
    dump_arr("mem/luts/sp_lut.mem",     _fx_sp_lut_q,  257);
    { FILE* fc=fopen("mem/luts/rope_cos.mem","w"); FILE* fs=fopen("mem/luts/rope_sin.mem","w");
      for(int i=0;i<512*4;i++){ fprintf(fc,"%d\n",_fx_cos_tbl[i]); fprintf(fs,"%d\n",_fx_sin_tbl[i]); }
      fclose(fc); fclose(fs); }
    /* kernel goldens: input Qq and expected output Qq, q=12 */
    FILE* f;
    f=fopen("mem/golden/kern_rsqrt.txt","w"); { int c=0; char buf[1<<16]; int off=0;
      for(long long v=64; v<=(1LL<<24); v=(v*3)/2){ off+=snprintf(buf+off,sizeof buf-off,"%lld %d\n",v,fx_rsqrt(v,12)); c++; }
      fprintf(f,"%d\n%s",c,buf); fclose(f); }
    f=fopen("mem/golden/kern_exp.txt","w"); { int c=0; char buf[1<<16]; int off=0;
      for(int z=0; z>=-16*4096; z-=137){ off+=snprintf(buf+off,sizeof buf-off,"%d %d\n",z,fx_exp_q(z,12)); c++; }
      fprintf(f,"%d\n%s",c,buf); fclose(f); }
    f=fopen("mem/golden/kern_sigmoid.txt","w"); { int c=0; char buf[1<<17]; int off=0;
      for(int z=-16*4096; z<=16*4096; z+=131){ off+=snprintf(buf+off,sizeof buf-off,"%d %d\n",z,fx_sigmoid_q(z,12)); c++; }
      fprintf(f,"%d\n%s",c,buf); fclose(f); }
    printf("luts + kernel goldens dumped\n");
    return 0;
}
