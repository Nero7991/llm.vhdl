#ifndef QUANT_H
#define QUANT_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
// Hardware-exact reference: int8 weight * int16 activation, int32 accumulate.
static inline int32_t dot_i8_i16(const int8_t* w, const int16_t* x, int n){
    int32_t acc = 0;
    for (int j=0;j<n;j++) acc += (int32_t)w[j] * (int32_t)x[j];
    return acc;
}
// Requantize an int32 accumulator back to int16 activation using a per-row
// power-of-two shift (the hardware uses an arithmetic shift). shift>=0.
static inline int16_t requant(int32_t acc, int shift){
    int32_t r = acc >> shift;              // arithmetic shift, matches RTL
    if (r >  32767) r =  32767;
    if (r < -32768) r = -32768;
    return (int16_t)r;
}
// Dump one matrix(ROWS x N) times vector(N) golden the RTL testbench reads.
// Called from within ref/runq.c when compiled with -DLLAMAVHDL_DUMP.
// Output file: mem/golden/matvec_<tag>.txt (path relative to repo root).
static inline void dump_matvec(const char* tag, const int8_t* W,
                               const int16_t* x, int n, int rows){
    char p[256]; snprintf(p,sizeof p,"mem/golden/matvec_%s.txt",tag);
    FILE* f=fopen(p,"w");
    if(!f){ fprintf(stderr,"dump_matvec: cannot open %s\n",p); exit(1); }
    fprintf(f,"%d %d\n",n,rows);
    for(int j=0;j<n;j++) fprintf(f,"%d ",x[j]); fprintf(f,"\n");
    for(int i=0;i<rows;i++){
        const int8_t* wr=W+(size_t)i*n;
        for(int j=0;j<n;j++) fprintf(f,"%d ",wr[j]);
        fprintf(f,"%d\n", dot_i8_i16(wr,x,n));
    }
    fclose(f);
}
#endif
