# gdn_conv: finding B-3 reproduced -- one `rd_req` mid-pass rewrites a segment

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. **No RTL was modified.** `rtl/gdn_conv.vhd`
and `rtl/gdn_exp_capture.vhd` are exactly as committed; the whole demonstration
is a new testbench, `sim/tb_gdn_conv_tvalid_skew.vhd`.
**Tools:** GHDL 1.0.0 mcode, `--std=08`, `ghdl -r` direct with `--stop-time` on
every run. **No Vivado** (place-and-route jobs were running on both machines).

## The question

From `docs/debugging/2026-08-27_B-interface-audit.md`, finding B-3, recorded as
CONFIRMED by source reading alone:

> `gdn_conv` reads `tvalid` combinationally throughout all of pass A (384
> cycles for the v segment), while `e_ref` and the per-tap shifts `shf(t)` are
> latched once at `S_PREP`. Its natural producer, `rtl/gdn_exp_capture.vhd`,
> drives `tvalid` as a free-running level that changes on any read request.
> ... A tap that is invalid at `S_PREP` gets `shf(t) = 0`; if that tap becomes
> valid mid-pass, its product is summed unshifted, on the wrong grid entirely.

The question: **is that reachable with the real producer, driven only through
its documented ports, or is something upstream making it safe?**

## The answer

**Reproduced, with the real `gdn_exp_capture` port-mapped straight into
`gdn_conv`, and the only stimulus being one ordinary `rd_req` for a different
(layer, segment) entry issued mid-pass.** Both directions of the defect fire.
A mid-pass narrowing corrupts a contiguous tail (128 of 256 channels, first
wrong channel exactly at the group the read was issued at). A mid-pass widening
is worse: the wrong-grid tail drags the segment's `amax`, so `sh_seg` moves
11 -> 13 and **all 256 channels are wrong, including the ones that were
computed correctly** -- the head comes out as the exact reference divided by
four, a silent two-bit precision loss with no flag set anywhere.

The trigger is specifically a read whose resulting mask differs. A re-read of
the *same* entry is clean, and a mid-pass *capture* is clean. Both were
measured, not inferred.

## The procedure that produced it

Ordered so that each step rules one thing out. The two prior notes in this
subsystem (`2026-08-27_gdn-emit-chain-w-latch.md`,
`2026-08-27_gdn-head-emit-done-pulse.md`) both turned on constructing the input
skew rather than on reading harder, and this follows their shape.

1. **Establish that the existing testbench cannot see it, and why.**
   `sim/tb_gdn_conv.vhd` assigns `tvalid` once per case, before `start`, and
   never touches it again. Its producer is maximally quiescent. Run as a
   baseline on the unmodified RTL it still reports
   `bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE
   4.99999999998181e-1 LSB`. So the unit is arithmetically correct and the
   question really is a concurrency property, exactly as with head 23 of
   `gdn_emit_chain`.

2. **Refuse to drive `tvalid` from the testbench.** The new testbench does not
   drive the port at all. `gdn_exp_capture`'s `tvalid` output is wired directly
   to `gdn_conv`'s `tvalid` input, and the testbench touches only `cap_req` and
   `rd_req`, respecting `cap_ready`. This is the difference between CONFIRMED
   and "reachable only with a producer that does not exist", and it was the one
   thing worth spending the extra effort on.

3. **Build the producer state the hazard needs.** Entry A (layer 0, seg 2) gets
   four captures, so `tvalid = 1111`. Entry B (layer 1, seg 0) gets four
   captures, then a `seq_rst`, then one more capture, so `tvalid = 1000` with
   all four tap bytes still *defined*. The `seq_rst`-then-one-capture shape is
   what token 0 of a new sequence actually looks like, and it also keeps `'U'`
   out of the comparison -- the trap the `gdn_exp_capture` testbench once fell
   into, where `to_integer` mapped both sides of an unwritten tap to 0 and the
   test passed.

4. **Pair every skew run with a CONTROL run.** Same entry, same data, same
   everything, with the mid-pass read simply not issued. If the control does
   not come out bit-exact against the in-testbench reference, nothing else in
   the run is interpretable, because the failure could be the testbench.

5. **Predict, do not just detect.** The testbench carries a model of the conv
   recipe parameterised by one extra knob, `gsplit` = the first *group* whose
   stage-2 mask is the new one while the *shifts* stay the ones latched at
   `S_PREP`. `gsplit = NB` is the correct reference. After each run it searches
   every `gsplit` in `0 .. NB` for one that reproduces the DUT bit for bit
   including `sh_seg` and `e_seg`. A match at exactly the group the read was
   issued at is a much stronger statement than "the numbers differ".

6. **Sweep the injection point.** `RDREQ_AT` is a generic. Sweeping it 1, 5,
   16, 25, 31 moves the first wrong channel to 8, 40, 128, 200, 248
   respectively and moves the matched `gsplit` with it. A single failure point
   could be a coincidence; five that track the stimulus are a mechanism.

7. **Kill the two alternative triggers explicitly.** CASE 3 re-reads the *same*
   entry mid-pass (the port is rewritten, with the same value) and CASE 4 does
   a *capture* mid-pass (the producer FSM runs and `cap_ready` drops). Both are
   clean. Without these the finding would have to be stated as "any producer
   activity corrupts", which is a larger and false claim.

## The evidence

Full run, `RDREQ_AT=16`, `CH_MAX=256`, `LANES=8`, `K=4`. Simulator output with
only the `file:line:` prefix and the `(report note)` tag stripped:

```
@655ns: ==== CASE 1 CONTROL  segment A, no mid-pass read ====
@905ns: MON  cycle 19: group 16 fetched (channels 128..135)
@1556ns:      S_PREP saw tvalid=1111  e_t(3..0)=6,2,5,3  -> e_ref=2  shf(3..0)=4,0,3,1
@1556ns:      tvalid at end of pass A = 1111
@1556ns:      sh_seg got 12 reference 12;  e_seg got -10 reference -10
@1556ns:      channels differing from the reference: 0 of 256   first=-1  last=-1
@1556ns:      masks identical (1111); gsplit search not applicable
@1556ns:      CONTROL OK: bit-exact with a quiescent producer

@1556ns: ==== CASE 1 SKEW     segment A, prefetch B at group 16 ====
@1805ns: MON  cycle 19: group 16 fetched (channels 128..135)
@1815ns: MON  cycle 20: group 17 fetched (channels 136..143)
@1825ns: MON  cycle 21: tvalid 1111 -> 1000   (first edge the DUT sees it)
@1825ns: MON  cycle 21: group 18 fetched (channels 144..151)
@2456ns:      S_PREP saw tvalid=1111  e_t(3..0)=6,2,5,3  -> e_ref=2  shf(3..0)=4,0,3,1
@2456ns:      tvalid at end of pass A = 1000
@2456ns:      sh_seg got 12 reference 12;  e_seg got -10 reference -10
@2456ns:      channels differing from the reference: 128 of 256   first=128  last=255
@2456ns:        head ch 128: got 16  expected -2848
@2456ns:        head ch 129: got 458  expected -602
@2456ns:        head ch 130: got -322  expected 5518
@2456ns:      DUT matches the CORRUPT model exactly, with the mask switching at group 16 (channel 128)
@2456ns:      SKEW DEMONSTRATED: 128 channels wrong

@2456ns: ==== CASE 2 CONTROL  segment B, no mid-pass read ====
@3356ns:      S_PREP saw tvalid=1000  e_t(3..0)=1,7,8,9  -> e_ref=1  shf(3..0)=0,0,0,0
@3356ns:      sh_seg got 11 reference 11;  e_seg got -10 reference -10
@3356ns:      channels differing from the reference: 0 of 256   first=-1  last=-1
@3356ns:      CONTROL OK: bit-exact with a quiescent producer

@3356ns: ==== CASE 2 SKEW     segment B, prefetch A at group 16 ====
@3605ns: MON  cycle 19: group 16 fetched (channels 128..135)
@3615ns: MON  cycle 20: group 17 fetched (channels 136..143)
@3625ns: MON  cycle 21: tvalid 1000 -> 1111   (first edge the DUT sees it)
@4256ns:      S_PREP saw tvalid=1000  e_t(3..0)=1,7,8,9  -> e_ref=1  shf(3..0)=0,0,0,0
@4256ns:      tvalid at end of pass A = 1111
@4256ns:      sh_seg got 13 reference 11;  e_seg got -12 reference -10
@4256ns:      channels differing from the reference: 256 of 256   first=0  last=255
@4256ns:        head ch 0: got 187  expected 748
@4256ns:        head ch 1: got -5817  expected -23266
@4256ns:        head ch 2: got 6014  expected 24055
@4256ns:        tail ch 128: got -5181  expected 507
@4256ns:        tail ch 129: got 3918  expected 14643
@4256ns:        tail ch 130: got 708  expected -10292
@4256ns:      DUT matches the CORRUPT model exactly, with the mask switching at group 16 (channel 128)
@4256ns:      SKEW DEMONSTRATED: 256 channels wrong

@4256ns: ==== CASE 3 SAME-ENTRY  segment A, re-read A at group 16 ====
@5156ns:      tvalid at end of pass A = 1111
@5156ns:      channels differing from the reference: 0 of 256   first=-1  last=-1
@5156ns:      CONTROL OK: bit-exact with a quiescent producer

@5156ns: ==== CASE 4 MID-CAPTURE  segment A, capture into B at group 16 ====
@6056ns:      tvalid at end of pass A = 1111
@6056ns:      channels differing from the reference: 0 of 256   first=-1  last=-1
@6056ns:      CONTROL OK: bit-exact with a quiescent producer

@6056ns: tb_gdn_conv_tvalid_skew: controls clean, see the SKEW blocks above
simulation finished @6057ns
```

### The exact skew, in cycles

Cycle 0 is the edge at which `gdn_conv`'s `S_IDLE` samples `start`. All five
sweep points give the same relation, which is what makes it a pipeline fact
rather than a coincidence:

| `RDREQ_AT` | group fetched at cycle | `tvalid` new value first readable at cycle | first wrong channel | matched `gsplit` |
|---|---|---|---|---|
| 1  | 4  | 6  | 8   | 1  |
| 5  | 8  | 10 | 40  | 5  |
| 16 | 19 | 21 | 128 | 16 |
| 25 | 28 | 30 | 200 | 25 |
| 31 | 34 | 36 | 248 | 31 |

**The offset is exactly 2 cycles, and it is the pass-A pipeline depth to the
mask read.** A group fetched at edge `F` reaches stage 1 (`p1 <= xf*wf`) at
`F+1` and stage 2 (`p2 <= shift_right(p1, shf(t))`, the statement that re-reads
`tvalid`) at `F+2`. `gdn_exp_capture` takes `rd_req` at edge `F`, is in `S_RD`
at `F+1` where it assigns `tvalid_r`, so the new mask is first readable at
`F+2` -- landing on that group's own stage 2. The group the read is issued at
is therefore the first group corrupted, every time.

### Why CASE 1 corrupts a tail and CASE 2 corrupts everything

CASE 1 (narrowing, `1111 -> 1000`) deletes three taps from the tail. Those
accumulators get smaller, `amax` is still set by the head, `sh_seg` stays 12,
and the damage is confined to channels 128..255. This is the "contiguous tail"
symptom the audit predicted.

CASE 2 (widening, `1000 -> 1111`) is the wrong-grid half. `S_PREP` saw only tap
3 valid, so `shf = 0,0,0,0`. When taps 0..2 turn valid at group 16 their
products are added **unshifted**, on a grid `2^8`, `2^7` and `2^6` away from
where they belong. Those accumulators blow past the head's magnitude, `amax`
grows, and the segment requantizer picks `sh_seg = 13` instead of 11. The head
channels, which were accumulated perfectly correctly, are then shifted two bits
further than they should be:

```
ch 0:   748 / 4 = 187        got 187
ch 1: -23266 / 4 = -5816.5   got -5817   (round-half-up)
ch 2:  24055 / 4 =  6013.75  got  6014
```

**A per-channel defect in the tail becomes a whole-segment two-bit precision
loss in the head**, because `bfp_pack` couples every channel through one
`amax`. Nothing reports it: `err_seg` stays `'0'`, `e_seg` moves to -12 which is
a perfectly legal int8, and the numbers stay plausible.

The coupling is magnitude-dependent, not structural. At `RDREQ_AT=31` only one
group of 8 channels is corrupted, its magnitudes do not exceed the head's, and
`sh_seg` stays at 11 -- so that run damages exactly 8 channels and leaves the
other 248 bit-exact. **The blast radius depends on the data**, which is the
worst property a silent defect can have for reproducibility.

## Measured and REJECTED -- do not retry

- **"A mid-pass capture is also a trigger."** Rejected by measurement, CASE 4.
  `gdn_exp_capture` assigns `tvalid_r` only in `S_RD` and on reset, so a
  capture runs the producer FSM and drops `cap_ready` without touching the
  seam. 0 of 256 channels differ. The finding is about reads, not about
  producer activity in general.
- **"A re-read of the same entry is a trigger."** Rejected by measurement,
  CASE 3. The port is genuinely rewritten mid-pass with the same value and the
  result is bit-exact. The trigger condition is that the resulting *mask*
  differs, which happens when the read targets a different (layer, segment), or
  the same one after a capture moved its saturating counter.
- **"`ready` is the safe instant a sequencer could use."** Rejected by reading
  the unit after the demonstration made the question concrete.
  `ready <= '1' when state = S_A`, which is true for the whole of pass A, so it
  marks "can accept a group", not "config taken". Every failing run here issues
  its read hundreds of nanoseconds after `ready` rose. There is no observable
  instant on this unit between `start` and `o_done`.
- **Driving `tvalid` directly from the testbench.** Not attempted, deliberately,
  and recorded here so nobody "simplifies" the testbench into it later. It
  would have produced a failure in about ten lines and would have proved
  nothing about reachability. The whole value of this note is that the skew
  comes out of the real producer.

## Measurement traps hit

- **A degenerate hypothesis search reports corruption on a clean run.** The
  first version searched `gsplit` in `0 .. NB` for a model matching the DUT and
  printed the first hit. On the CONTROL runs the two masks are identical, so
  every `gsplit` is the same model and `gsplit = 0` matched -- printing
  *"DUT matches the CORRUPT model exactly, with the mask switching at group 0"*
  directly above *"CONTROL OK: bit-exact"*. Both lines were true and together
  they were nonsense. Guarded now: the search is skipped when `m1 = m2`. **A
  parameterised model whose parameter is unidentifiable will still hand you a
  parameter value.**
- **Reading a signal at a rising edge yields its pre-edge value.** The monitor
  reports a `tvalid` change one edge after `gdn_exp_capture` assigns it. That
  is not an error to correct, because `gdn_conv`'s stage 2 reads it the same
  way, so the printed cycle is exactly the first edge the DUT sees the new
  mask. It is called out in the testbench because subtracting the offset
  "for correctness" would break the +2 relation in the table above. Same class
  as trap 4 of `2026-08-26_gdn-conv-cycle-model.md`.
- **A VHDL identifier may not end in `_`.** `variable on_ : boolean` gave four
  `an identifier cannot finish with '_'` errors with no hint of the actual rule.
  Thirty seconds, but the message does not say "rename it".
- **`ghdl -e` produces no binary on mcode and exits 0.** Known in this repo,
  restated because it is the first thing that wastes an hour for a new reader.
  `ghdl -r <entity>` directly. Analysis order: `fixed_luts_pkg`, `fixed_pkg`,
  `util_pkg`, `gdn_conv`, `gdn_exp_capture`, then the testbench.
- **The clock is guarded and the run calls `std.env.finish`.** Total sim time is
  ~6 us, so this one never risked the 4h58m runaway, but a `--stop-time` was
  passed on every invocation anyway.

## The proposed fix -- NOT applied

`rtl/gdn_conv.vhd` was deliberately left untouched. What follows is the
proposal.

### Shape: latch at a defined instant, plus a `_taken` pulse

This is class 1, the same class as `w_mant` in `gdn_emit_chain`, so it wants the
`w_mant` fix and not the `gdn_head_emit` one. The `done`-held-until-`o_ack`
shape solves a *producer losing an event*; here nothing is lost, the consumer is
reading a level that moves under it. Concretely:

1. **Latch the mask.** Add `signal tv_r : std_logic_vector(K-1 downto 0);`,
   assign `tv_r <= tvalid;` in `S_PREP` beside the existing `e_ref` and `shf`
   derivation, and change the single pass-A stage-2 test from `tvalid(t)` to
   `tv_r(t)`. The mask and the shifts then come from the same instant by
   construction, which is the entire defect.
2. **Latch `cw_exp` at the same instant** into `cw_r`, and use `cw_r` in
   `S_FIN`. This closes **B-3b** for free: `cw_exp` is currently read only at
   `S_FIN`, hundreds of cycles after `start`, and a port read once at the *end*
   of a long operation is the least visible member of the class.
3. **Publish `cfg_taken`**, a one-cycle output asserted on the edge that leaves
   `S_PREP`. That is the instant after which `e_t`, `tvalid` and `cw_exp` may
   change. Today the unit publishes no such instant: `ready` is high for all of
   pass A and `o_done` is a whole invocation late, so a sequencer has no legal
   way to know when it may prefetch.
4. **Add a simulation-only assertion** that `tvalid` and `e_t` are stable from
   the `start` edge to `cfg_taken` (a 2-cycle window). The latch makes the long
   window safe; the assertion covers the short one, which the latch cannot.

An alternative that needs no new port -- fold the mask into the shift by giving
invalid taps a sentinel shift that zeroes the product -- is a real option and
saves the `tv_r` flops, but it removes the mask from the source without
removing the *contract* problem, and step 3 is the part that a future sequencer
actually needs. Prefer the explicit latch.

### Cost

- **13 flip-flops at `K = 4`**: 4 for `tv_r`, 8 for `cw_r`, 1 for `cfg_taken`.
  No DSP, no BRAM, no extra state, no extra cycle -- `S_PREP` already exists and
  already runs for one cycle.
- **Timing: neutral or slightly better.** The stage-2 select currently sources
  from an input port that arrives from `gdn_exp_capture`'s output register
  across whatever placement distance the two units end up with; after the fix it
  sources from a local flop inside `gdn_conv`. The mux itself is unchanged.
- **NOT SYNTHESIZED.** Both machines were running place-and-route and a third
  Vivado job was out of scope for this session, so the 13 FF is a count of
  declared registers, not a measured utilisation delta, and the timing claim is
  an argument from fanin, not a report.
- **One new output port**, so every future instantiation must decide whether to
  connect `cfg_taken`. Leaving it dangling is safe.

### What the fix does NOT cost, and the alternative that does

The purely-documentary alternative -- "the sequencer must not touch the read
port while a conv is running" -- costs cycles rather than flops, and the bill is
large. The unsafe window runs from `start` to the last stage-2 read, and nothing
marks its end, so a sequencer obeying an observable contract has to wait for
`o_done`: pass A plus pass B plus drain, roughly `2*nch/LANES + 20` cycles, or
about **790 cycles for the v segment** during which the shared exponent-capture
read port must sit idle. Thirteen flops is cheaper. This is the same argument
the `w_mant` note made when it rejected "just document the timing contract",
and it is stronger here because there the safe window at least existed.

### Residual weakness, stated rather than hidden

`cfg_taken` inherits `w_taken`'s known problem, already logged as B-6: it is a
pulse with no back-pressure, so a producer that changes `tvalid` *before* it
fires is not stopped, only detected by the assertion in step 4. Fixing that
properly means a `cfg_valid` / `cfg_taken` handshake on the config group, which
is a bigger change than B-3 warrants on its own but is the right shape if B-4's
five other unlatched-at-`start` units are ever addressed together.

## What I could not determine

- **Whether any real sequencer will actually issue the offending read.**
  Subsystem B still has no top level; `gdn_conv` and `gdn_exp_capture` are not
  wired together anywhere in the tree. This note proves the seam is unsafe as
  specified, not that a build exists which breaks. That is the same standing
  the audit itself claims, and it is the standing the `w_mant` defect had right
  up until the day the seam was made and it was written in immediately.
- **The real segment sizes were not exercised.** Everything here is
  `CH_MAX=256, LANES=8`, i.e. 32 groups. The shipping v segment is
  `nch = 3072`, a 384-cycle pass A, which widens the vulnerable window by 12x
  but changes nothing structural. Not run, because it costs sim time and adds
  no information.
- **The blast radius as a function of data.** `RDREQ_AT=31` corrupted 8
  channels and `RDREQ_AT=16` corrupted 256, purely because of whether the
  corrupt tail wins `amax`. One seed was used. No attempt was made to
  characterise the distribution, and any statement of the form "typically N
  channels" would be unsupported.
- **Whether `e_t` alone can do damage.** It cannot in the current source --
  `e_t` is read only at `S_PREP` -- but that was established by reading, not by
  a mutation, so it rests on the same kind of evidence the audit already had.
- **Nothing was synthesized.** No Fmax, no utilisation, before or after.

## Reproducing

```
cd sim
WD=<some workdir>
ghdl -a --std=08 --workdir=$WD ../rtl/fixed_luts_pkg.vhd ../rtl/fixed_pkg.vhd \
     ../rtl/util_pkg.vhd ../rtl/gdn_conv.vhd ../rtl/gdn_exp_capture.vhd \
     tb_gdn_conv_tvalid_skew.vhd

# the demonstration; terminates on its own via std.env.finish
ghdl -r --std=08 --workdir=$WD tb_gdn_conv_tvalid_skew --stop-time=2ms

# move the injection point; the first wrong channel follows it
ghdl -r --std=08 --workdir=$WD tb_gdn_conv_tvalid_skew -gRDREQ_AT=31 --stop-time=2ms

# the unmodified unit testbench, as a baseline (ends in `wait;`, so it must be
# killed after its report line)
ghdl -a --std=08 --workdir=$WD tb_gdn_conv.vhd
ghdl -r --std=08 --workdir=$WD tb_gdn_conv --stop-time=50ms
```
