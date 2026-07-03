// hw/mac_test.c — drive the PL mac_axi over /dev/mem and check vs software.
// Base 0x800F0000 (the address assigned in design_1; distinct from the fan @0x80090000).
// Cross-compile: aarch64-linux-gnu-gcc -O2 -static hw/mac_test.c -o mac_test
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define BASE      0x800F0000UL
#define CTRL      0x00
#define STATUS    0x04
#define NREG      0x08
#define LOAD_IDX  0x0C
#define LOAD_ACT  0x10
#define LOAD_W    0x14
#define RESULT_LO 0x18
#define RESULT_HI 0x1C
#define ID        0x20
#define N 64

static volatile uint32_t* reg;
static void     wr(unsigned off, uint32_t v){ reg[off/4] = v; }
static uint32_t rd(unsigned off){ return reg[off/4]; }

int main(void){
    int fd = open("/dev/mem", O_RDWR|O_SYNC);
    if(fd<0){ perror("/dev/mem"); return 1; }
    void* m = mmap(0, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, BASE);
    if(m==MAP_FAILED){ perror("mmap"); return 1; }
    reg = (volatile uint32_t*)m;

    uint32_t id = rd(ID);
    printf("ID = 0x%08x (expect 0x6d414331)\n", id);

    int act[N], w[N]; long expect = 0;
    for(int i=0;i<N;i++){
        act[i] = (i % 7) - 3;    // -3..3 (signed), same as the GHDL TB
        w[i]   = (i % 5) + 1;    // 1..5 (positive; keeps the sum from cancelling)
        expect += (long)act[i]*w[i];
    }
    wr(NREG, N);
    for(int i=0;i<N;i++){
        wr(LOAD_IDX, i);
        wr(LOAD_ACT, (uint32_t)(int32_t)act[i]);
        wr(LOAD_W,   (uint32_t)(int32_t)w[i]);
    }
    wr(CTRL, 1);                                  // START
    int done=0;
    for(int t=0; t<1000000; t++){ if(rd(STATUS)&1){ done=1; break; } }
    int64_t acc = ((int64_t)(int32_t)rd(RESULT_HI) << 32) | rd(RESULT_LO);

    printf("done=%d  PL result = %lld,  software = %ld  ->  %s\n",
           done, (long long)acc, expect, (done && acc==expect) ? "PASS" : "FAIL");

    munmap(m, 0x1000); close(fd);
    return (done && acc==expect) ? 0 : 1;
}
