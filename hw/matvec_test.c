/* matvec_test.c -- replay the fx_matvec_wq_l0 golden through the on-silicon
 * mac_axi MAC and verify all 64 output-row accumulators match bit-for-bit.
 * Proves the PL MAC computes a real transformer matvec (layer-0 Wq * activation)
 * with real model weights -- no new bitstream, just the deployed mac_axi.
 *
 * Golden format (mem/golden/fx_matvec_wq_l0.txt):
 *   line1: d n           (rows, cols)
 *   line2: EXP <xe>
 *   line3: n int16 activation mantissas
 *   d rows: <n int16 weight mantissas> <int64 acc>
 *
 * Build: aarch64-linux-gnu-gcc -O2 -static hw/matvec_test.c -o /tmp/matvec_test
 * Run on board: /tmp/matvec_test /tmp/fx_matvec_wq_l0.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define BASE 0x800F0000UL
#define CTRL      0x00
#define STATUS    0x04
#define N_REG     0x08
#define LOAD_IDX  0x0C
#define LOAD_ACT  0x10
#define LOAD_W    0x14
#define RESULT_LO 0x18
#define RESULT_HI 0x1C
#define ID_REG    0x20

static volatile uint32_t *reg;
static inline void wr(int off, uint32_t v){ reg[off/4]=v; }
static inline uint32_t rd(int off){ return reg[off/4]; }

int main(int argc, char**argv)
{
    const char *gf = (argc>1)? argv[1] : "/tmp/fx_matvec_wq_l0.txt";
    FILE *f = fopen(gf,"r");
    if(!f){ perror("golden"); return 1; }
    int d,n,xe;
    if(fscanf(f,"%d %d",&d,&n)!=2){ fprintf(stderr,"hdr\n"); return 1; }
    if(fscanf(f," EXP %d",&xe)!=1){ fprintf(stderr,"exp\n"); return 1; }
    int16_t *xm = malloc(n*sizeof(int16_t));
    for(int j=0;j<n;j++){ int v; fscanf(f,"%d",&v); xm[j]=(int16_t)v; }

    int fd = open("/dev/mem", O_RDWR|O_SYNC);
    if(fd<0){ perror("/dev/mem"); return 1; }
    reg = mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,BASE);
    if(reg==MAP_FAILED){ perror("mmap"); return 1; }

    uint32_t id = rd(ID_REG);
    printf("ID = 0x%08x (expect 0x6d414331)\n", id);
    if(id!=0x6d414331){ fprintf(stderr,"bad ID, wrong bitstream?\n"); return 2; }

    wr(N_REG, n);
    /* load the shared activation vector once (persists in act_store) */
    for(int j=0;j<n;j++){ wr(LOAD_IDX,j); wr(LOAD_ACT,(uint32_t)(uint16_t)xm[j]); }

    int pass=0, fail=0;
    for(int i=0;i<d;i++){
        int16_t *wm = malloc(n*sizeof(int16_t));
        for(int j=0;j<n;j++){ int v; fscanf(f,"%d",&v); wm[j]=(int16_t)v; }
        long long exp_acc; fscanf(f,"%lld",&exp_acc);
        /* load weight row */
        for(int j=0;j<n;j++){ wr(LOAD_IDX,j); wr(LOAD_W,(uint32_t)(uint16_t)wm[j]); }
        /* run */
        wr(CTRL,1);
        int spins=0; while(!(rd(STATUS)&1)){ if(++spins>1000000){fprintf(stderr,"timeout row %d\n",i); return 3;} }
        uint32_t lo=rd(RESULT_LO), hi=rd(RESULT_HI);
        int64_t acc = (int64_t)(((uint64_t)hi<<32)|lo);
        if(acc==exp_acc) pass++;
        else { if(fail<8) printf("  row %2d MISMATCH pl=%lld golden=%lld\n", i, (long long)acc, exp_acc); fail++; }
        free(wm);
    }
    fclose(f);
    printf("matvec Wq layer0: %d/%d rows match  ->  %s\n", pass, d, fail? "FAIL":"PASS");
    return fail? 4:0;
}
