/* matvec_engine_test.c -- validate the autonomous matvec_engine on silicon.
 * Weights (layer-0 Wq) live in the engine's on-chip BRAM ROM; we only load the
 * activation vector, START, and read back all 64 output-row int48 accumulators,
 * comparing to the fx_matvec_wq_l0 golden. Proves the PL streams a full
 * matrix-vector product from BRAM-resident real model weights, autonomously.
 *
 * Build: aarch64-linux-gnu-gcc -O2 -static hw/matvec_engine_test.c -o /tmp/matvec_engine_test
 * Run:   /tmp/matvec_engine_test /tmp/fx_matvec_wq_l0.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define BASE 0x80100000UL
#define CTRL     0x00
#define STATUS   0x04
#define DIMS     0x08
#define LOAD_IDX 0x0C
#define LOAD_ACT 0x10
#define ROW_IDX  0x14
#define ACC_LO   0x18
#define ACC_HI   0x1C
#define ID_REG   0x20

static volatile uint32_t *reg;
static inline void wr(int o,uint32_t v){ reg[o/4]=v; }
static inline uint32_t rd(int o){ return reg[o/4]; }

int main(int argc,char**argv)
{
    const char *gf = argc>1?argv[1]:"/tmp/fx_matvec_wq_l0.txt";
    FILE *f=fopen(gf,"r"); if(!f){perror("golden");return 1;}
    int d,n,xe;
    if(fscanf(f,"%d %d",&d,&n)!=2){fprintf(stderr,"hdr\n");return 1;}
    if(fscanf(f," EXP %d",&xe)!=1){fprintf(stderr,"exp\n");return 1;}
    int16_t *xm=malloc(n*sizeof(int16_t));
    for(int j=0;j<n;j++){int v;if(fscanf(f,"%d",&v)!=1){fprintf(stderr,"act\n");return 1;}xm[j]=(int16_t)v;}
    /* read expected accumulators (skip the weight mantissas on each row) */
    int64_t *exp_acc=malloc(d*sizeof(int64_t));
    for(int i=0;i<d;i++){
        for(int j=0;j<n;j++){int v;if(fscanf(f,"%d",&v)!=1){fprintf(stderr,"w\n");return 1;}}
        long long a;if(fscanf(f,"%lld",&a)!=1){fprintf(stderr,"acc\n");return 1;}
        exp_acc[i]=a;
    }
    fclose(f);

    int fd=open("/dev/mem",O_RDWR|O_SYNC); if(fd<0){perror("/dev/mem");return 1;}
    reg=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,BASE);
    if(reg==MAP_FAILED){perror("mmap");return 1;}

    uint32_t id=rd(ID_REG);
    printf("ID = 0x%08x (expect 0x6d415631)\n", id);
    if(id!=0x6d415631){fprintf(stderr,"bad ID - wrong bitstream?\n");return 2;}
    uint32_t dims=rd(DIMS);
    printf("DIMS: OUT=%u IN=%u  (golden d=%d n=%d)\n", dims>>16, dims&0xffff, d, n);

    /* load activation vector (weights are in the engine's ROM) */
    for(int j=0;j<n;j++){ wr(LOAD_IDX,j); wr(LOAD_ACT,(uint32_t)(uint16_t)xm[j]); }
    /* run the whole matvec */
    wr(CTRL,1);
    int spins=0; while(!(rd(STATUS)&1)){ if(++spins>2000000){fprintf(stderr,"timeout\n");return 3;} }

    int pass=0,fail=0;
    for(int i=0;i<d;i++){
        wr(ROW_IDX,i);
        uint32_t lo=rd(ACC_LO),hi=rd(ACC_HI);
        int64_t acc=(int64_t)(((uint64_t)hi<<32)|lo);
        if(acc==exp_acc[i]) pass++;
        else { if(fail<8) printf("  row %2d MISMATCH pl=%lld golden=%lld\n",i,(long long)acc,(long long)exp_acc[i]); fail++; }
    }
    printf("autonomous matvec (BRAM-ROM Wq): %d/%d rows match -> %s\n", pass, d, fail?"FAIL":"PASS");
    return fail?4:0;
}
