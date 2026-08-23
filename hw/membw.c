/* Minimal DRAM read-bandwidth probe for the board's own cores.
 * Working set is far larger than the 1 MB L2 so every read is a DRAM read.
 * Reports GB/s so it can be compared directly against the PL's counters. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
int main(int argc, char **argv) {
    size_t mb = argc > 1 ? (size_t)atoi(argv[1]) : 256;
    double secs = argc > 2 ? atof(argv[2]) : 3.0;
    size_t n = mb << 20, elems = n / sizeof(unsigned long);
    unsigned long *b = malloc(n);
    if (!b) { perror("malloc"); return 1; }
    memset(b, 1, n);
    struct timespec t0, t1;
    unsigned long acc = 0; double el = 0; size_t passes = 0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    do {
        for (size_t i = 0; i < elems; i += 8) acc += b[i];   /* one per 64 B line */
        passes++;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    } while (el < secs);
    printf("%.2f GB/s  (%zu MB x %zu passes in %.2f s, acc=%lu)\n",
           (double)n * passes / el / 1e9, mb, passes, el, acc);
    return 0;
}
