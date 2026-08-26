# Decision needed: does the 27B target still gate the project?

**Written 2026-08-25 overnight, for a decision, not as a finding.**
Nothing here needs hardware that is not already on the desk. It exists because
the PCIe/two-card dependency has never been tested and is aging while
everything downstream of it gets refined.

## The one-paragraph version

The 27B model **cannot** run on one FK33: 14.09 GiB at 4.5 bpw against 8 GiB of
HBM. So the 27B target *is* N=2, N=2 *is* subsystem E, and E rests on PCIe P2P
between two cards behind a common switch -- **none of which has ever been
tested, on a workstation whose own topology documents say it cannot provide
it.** Meanwhile a single-card **9B** rung already exists in the ladder
(A §15 `v4.0`), needs no second card, no P2P and no subsystem E at all, and
tonight's measured bandwidth prices it at **~56 tok/s**. The decision is
whether v3.0 means 27B-on-two-cards or 9B-on-one, and it is currently being
answered by default.

## What is actually blocked, and what is not

| | 9B, one card | 27B, two cards |
|---|---|---|
| Fits HBM? | 5.1 GB of 8 GiB, **yes**, ~2.9 GiB spare | 7.63 GB per card, yes **only at N=2** |
| Needs subsystem E? | **No** | Yes, and E §3 is unwritten |
| Needs PCIe P2P? | **No** | Yes, and it is untested |
| Needs a second FK33? | No | Yes |
| Needs a chassis that can host both behind one switch? | No | **Yes, and this workstation cannot** |
| Weight-stream floor at the MEASURED 288 GB/s | 17.7 ms, **56.5 tok/s** | 26.5 ms, 37.7 tok/s per card |
| Same floor at the refuted 460.8 GB/s premise | 11.1 ms, 90.4 tok/s | 16.6 ms, 60.4 tok/s |

Two things in that table are worth saying out loud.

**The ladder's tok/s figures are all quoted against 460.8 GB/s, which is
refuted.** Measured usable bandwidth is 288.0 GB/s read-only (30 ports x 32 B x
300 MHz) and 353.0 GB/s if traffic is bidirectional; A's weight stream is
read-only, so A gets 288. Every ceiling in A §15's ladder is therefore ~1.6x
optimistic. That is a correction to make regardless of which target is chosen.

**Going to one card does not halve throughput, it roughly halves the model.**
9B on one card is *faster* than 27B on two (56.5 vs 37.7 tok/s at the same
measured bandwidth), because per-card weight bytes fall further than the
parallelism gains. The 27B target buys model quality, not speed.

## What cannot be advanced without hands or money

- **Whether an FK33 enumerates on PCIe at all.** No FK33 has ever appeared in
  `lspci` on this workstation; every result to date, including tonight's 288
  and 353 GB/s, went over JTAG. This is a slot test, not an experiment: seat
  the card, boot, look. Ten minutes with the case open.
- **Whether XDMA works**, which is how weights would ever be loaded. There is
  currently **no non-JTAG path to get 7.11 GiB into HBM**, and JTAG is not an
  engineering answer for that volume.
- **Whether two cards can do P2P behind a common switch.** `docs/fpga-hardware-recon.md`
  §4b calls P2P "the load-bearing assumption" and prescribes buying two FK33s
  and proving it first. The workstation's own topology notes say its GPUs
  already sit on different root complexes and report `CNS` (Chipset Not
  Supported) for peer traffic; there is one CPU-connected x16 slot and the
  others are chipset x4. **A second card in this chassis would reproduce the
  failure, not test around it.**

## What I would do, and why

**Split the target rather than choosing between them.** Make **9B on one card
the committed v-next**, and keep 27B as the stretch that a chassis decision
unblocks later. Concretely:

1. It removes subsystem E from the critical path entirely. E §3 is unwritten
   and E is the only subsystem whose design depends on hardware nobody has.
2. Every piece of RTL written so far serves both. `rmsnorm_rs`, `l2norm_rs`,
   A's matvec, B's sweep, C's attention and D's sequencer are all
   dimension-parametric; the 9B differs in `LANES`, layer counts and shard
   arithmetic, not in structure.
3. It makes the PCIe question a **prerequisite for a stretch goal** instead of
   a silent precondition for the main one -- which is what it has been.
4. It is the honest reading of the resource position. Tonight's work put the
   whole-die DSP at **89.5% of 2,880 with every term measured** (B §3.6), i.e.
   at the 90% congestion line, for 27B dimensions. [**Corrected 2026-08-26:
   89.5% is withdrawn. Rebuilt with B's scalar path measured at 7 DSP rather
   than guessed, C's QK-norm at its real 22, and conv re-measured at the true
   segment shapes, the honest range is 2,606 to 2,648 of 2,880 = 90.5% to
   91.9%. The argument below is unaffected in direction and strengthened in
   degree: the die is over the congestion line, not at it.**] The 9B's smaller per-layer
   work is the one lever that moves that number without giving up a subsystem.

**What I would NOT do:** try to make 27B fit one card by quantising harder.
Fitting 27B in ~6.5 GiB needs about **2.1 bits per weight**, against the 4.5
the whole numeric contract is built on. That is not a knob, it is a different
project.

## The three things to check before deciding

1. **Does an FK33 enumerate on PCIe in this machine?** If no, the 27B path is
   blocked on hardware nobody has verified, and the decision makes itself.
2. **Are the 9B's GDN dimensions verified?** B §2.9 says explicitly they are
   **not** (`ssm_dt_rank`, `ssm_d_inner`, 32 layers with a 3:1 hybrid -> 24 GDN
   layers, all unverified). That verification is a `gguf` read, not a build,
   and it is the one piece of homework the 9B path needs.
3. **Is 56 tok/s on 9B worth more than 38 tok/s on 27B?** That is a product
   question and it is the user's, not mine. The numbers above are the honest
   inputs to it, at measured bandwidth rather than the refuted premise.

## Open, not answered here

- The 56.5 and 37.7 tok/s figures are **weight-stream floors only** -- pure
  bandwidth, ignoring B, C, D and every seam. A §15's derated column applies
  ~70% for that, which tonight's measurements did not test and which the
  refuted 460 GB/s premise was tangled up with. Treat them as ceilings for
  comparing the two paths, not as predictions.
- The 9B rung's own resource fit has never been computed. The whole-die DSP
  figure (89.5% as written here, **90.5%-91.9% as corrected 2026-08-26**) is
  27B dimensions; 9B has not been summed.
