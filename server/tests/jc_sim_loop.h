/* server/tests/jc_sim_loop.h -- a C model of rtl/tok_loop.vhd's host-visible behaviour, for
 * jc_sim_broker --loop (plan 2026-11-04 Task 7). It drives the simulated seam through the
 * same transport the broker serves, with the write sequence of tok_loop_fsm (which Task 2
 * pinned to run_prompt's), so tools/jc/jc_loop.py can be tested against run_prompt's ids
 * without hardware. Not an oracle for the RTL: the GHDL benches are. NO HARDWARE. */
#ifndef JC_SIM_LOOP_H
#define JC_SIM_LOOP_H
#include <stdint.h>
#include "../fk33_transport.h"

#define JC_LOOP_BASE 0x20000u
#define JC_LOOP_SPAN 0x10000u

typedef struct jc_loop jc_loop;
jc_loop *jc_loop_new(fk33_transport *t, unsigned n_embd);
int  jc_loop_rd(jc_loop *L, uint32_t off, uint32_t *v);    /* off inside the loop window */
int  jc_loop_wr(jc_loop *L, uint32_t off, uint32_t v);
int  jc_loop_owns_seam(const jc_loop *L);                   /* host seam access is refused */
void jc_loop_tick(jc_loop *L);                              /* run until blocked */
void jc_loop_pair(jc_loop *a, jc_loop *b);                  /* a's frames go to b */
void jc_loop_drop(jc_loop *a, unsigned long nth);           /* corrupt a's nth frame (1-based) */
#endif
