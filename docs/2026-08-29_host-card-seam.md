# The host/card seam, v2: prefill, then decode returning logits

**Status:** definition, 2026-08-29. The host half is implemented and tested
(`server/pl_backend.{h,c}`, `server/fk33_{transport,seam,sim}.*`). **The card
half does not exist.** Nothing in this document has run against silicon.

The machine-readable copy is `server/fk33_seam.h` and the two must agree.
Where they do not, **the header wins, because the header is compiled.**

---

## 1. The answer, up front

The seam moves from GENERATION-level to **PREFILL + DECODE-RETURNING-LOGITS**.

| | crosses | direction | units | owner |
|---|---|---|---|---|
| activation | `n_embd` int16 mantissas + 1 int32 block exponent | host to card | 8,208 B at n_embd 4096 | host builds it |
| logits | `n_vocab` int32 + 1 int32 shared block exponent | card to host | 993,296 B at n_vocab 248,320 | card writes it |
| argmax | 1 int32 | card to host | 4 B, one BAR read | card computes it |
| position | 1 int32 | host to card | `SEQ_POS` | host owns it |
| KV cache | **nothing** | -- | 17,408 B/token, stays on the card | card owns it |
| weights | the whole packed image | host to card | once, at cold start | host owns the image |
| descriptor program | a 64-bit pointer | host to card | `DESC_PTR` | nobody yet (OI-4) |

The host owns the loop, the sampler, the tokenizer, the chat template, the
stop-string matching, the detokenizer, the embedding gather, and the sequence
position. The card owns the weights, the 32 blocks, the KV bytes, and the
lm_head's 15 subsystem-A jobs.

---

## 2. Why it moved. Four rows, not a preference

| | AXU3EG (v1) | FK33 (v2) |
|---|---|---|
| host | a PS on the same die | a real host, over PCIe Gen3 x4 |
| loop | the engine ran it | the host must |
| sampler | a fabric argmax, no logits port | `top_p` needs logits, and they are affordable |
| access cost | `/dev/mem` mmap, ~ns | non-posted BAR read ~1-2 us, DMA round trip ~20-40 us |
| capacity | MAXPOS 24, VOCAB 512 | 198,415-token KV, 248,320 vocab |

The access-cost row forces the shape. On the AXU3EG a per-token host round trip
would have been most of a token, so putting the loop in the fabric cost nothing
and bought a smaller design. Over PCIe a round trip is ~20-40 us against a
**38.27 ms** token (`docs/2026-08-28_token-io-path.md`), i.e. ~0.1%. Once the
host can afford the loop, temperature, `top_p`, seeds, logit bias, stop
sequences, speculative decoding and multi-sequence scheduling all become
ordinary software that can be tested on a laptop.

`server/pl_backend_axu3eg.{h,c}` is retained unchanged for the AXU3EG, with its
symbols renamed `plv1_*`. Same reason `rtl/matvec_int4_axi.vhd` was kept beside
`rtl/matvec_int4_desc_axi.vhd`: that arm is real and nothing about the FK33
invalidates it.

---

## 3. Is returning ~1 MB per token affordable? DERIVED

Measured link rates, `docs/debugging/2026-08-28_fk33-first-light.md:141`:
H2C **3.27 GB/s**, C2H **1.11 GB/s**.

```
host -> card    8,208 B / 3.27e9 B/s  =   2.51 us   0.0066% of a 38.27 ms token
card -> host  993,296 B / 1.11e9 B/s  = 894.9  us   2.34%   of a token
argmax only         4 B                             ~0%
```

So yes, and by a wide margin. Two caveats, both stated rather than buried:

- **ESTIMATE, not MEASURED.** It applies the 1 GB-transfer rate to a 1 MB
  transfer. `docs/2026-08-28_token-io-path.md` says in its own words that **no
  small-transfer latency has ever been measured on this card**, so the
  per-transfer setup cost is unmodelled and the real figure is worse. This is
  the first thing to measure when a card can answer.
- **C2H is one third of H2C and nobody knows why.** First light recorded it as
  "unexplained, not blocking", and it fails the bring-up plan's own >= 2.5 GB/s
  criterion. The logits path is the first thing in this project that cares.

The greedy fast path (`logits = NULL`) skips the C2H entirely and reads the
card's own running argmax as four bytes. A greedy server should use it. A
server honouring `temperature` or `top_p` cannot.

---

## 4. The register block

**The base offset is PROPOSED, not decided.** `hw/fk33/gen_pcieep.py`
configures the block design and therefore owns every BAR offset; the track that
wrote this does not own that file. `0xE000` is the largest free 4 KB hole below
the scratch BRAM. MEASURED BAR occupancy today, from
`hw/fk33/host/fk33_regs.h` and `docs/2026-08-27_fk33-pcie-bringup-procedure.md`:
`0x3400` SYSMON, `0x9000` GPIO, `0xA000` ID, `0xB000`/`0xC000`/`0xD000`
thermal, `0x10000`+8 KB scratch.

| off | name | acc | meaning |
|---|---|---|---|
| 0x00 | `ID` | R | `0x4C4C4D32` = "LLM2" |
| 0x04 | `VERSION` | R | contract version, = 1 |
| 0x08 | `CAPS_VOCAB` | R | `n_vocab` |
| 0x0C | `CAPS_EMBD` | R | `[15:0] n_embd`, `[31:16] n_layer` |
| 0x10 | `CAPS_CTX` | R | KV capacity, in tokens |
| 0x14 | `CTRL` | W | bit0 `GO`, bit1 `SEQ_RESET`, bit2 `LOGITS_ALL`; all self-clearing |
| 0x18 | `STATUS` | R | bit0 done (latched), bit1 busy, bit2 err, `[11:8]` err_code |
| 0x1C | `ERR_INFO` | R | |
| 0x20 | `SEQ_POS` | RW | position this GO's step 0 occupies |
| 0x24 | `N_STEP` | RW | positions this GO advances |
| 0x28/0x2C | `X_BASE_LO/HI` | W | activation block |
| 0x30/0x34 | `L_BASE_LO/HI` | W | logits block |
| 0x38/0x3C | `DESC_PTR_LO/HI` | W | the per-token D program, 512-byte aligned |
| 0x40 | `CYCLES` | R | core cycles, GO to done |
| 0x44 | `ARGMAX` | R | argmax of the LAST step |
| 0x48 | `LOGIT_EXP` | R | its shared block exponent |

**Discovery, not assumption.** `CAPS_*` exist for the same reason subsystem A's
`CAPS`/`ADDR_CAP`/`DESC_WORDS` do: a host must be able to learn the shape of
the build it is talking to, so a driver and a bitstream cannot silently
disagree. `pl_backend` reads all three and refuses implausible values.

**`done` is latched and is NEVER set on an error.** This is A's rule, restated,
and the descriptor-format document is explicit that a done-only poller hangs
forever. `pl_backend`'s `seam_wait()` is the only spelling of the wait in this
tree and it polls `(done | err)` with a timeout. `server/fk33_sim.c` reproduces
the trap under `fault_never_done` and `fault_err_on_go`, and
`server/tests/seam_selftest.c` T7 shows both firing.

**The error codes live in their own register and do not extend A's.** A's
4-bit `err_code` space is FULL (OI-9). A shared field with two meanings per
value is how an error report becomes fiction.

| code | meaning |
|---|---|
| 0x1 `POS` | `SEQ_POS + N_STEP` past the KV capacity |
| 0x2 `NSTEP` | `N_STEP` = 0, or above the chunk cap |
| 0x3 `ALIGN` | a block base is not 64-byte aligned, or `DESC_PTR` not 512 |
| 0x4 `STACK` | a block straddles the HBM stack boundary |
| 0x5 `RSVD` | a reserved field was not zero, or the blocks overlap |
| 0x6 `DESC` | the descriptor program was refused |
| 0x7 `HALT` | the thermal guard refused the GO |
| 0x8 `SEQ` | `SEQ_POS` is not the card's own next position |

`SEQ` deserves its own line. The card knows what position it is at; the host
tells it what position it thinks it is at; they are compared. Without that, a
host whose KV bookkeeping is one step out gets plausible tokens computed
against the wrong cache, and nothing anywhere notices.

---

## 5. The two blocks in HBM

Activation block at `X_BASE`, `N_STEP` entries, stride
`round_up(16 + 2*n_embd, 64)` = **8,256 B** at n_embd 4096:

```
+0x00  i32   x_exp        the row's BFP block exponent
+0x04  u32   token_id     informational; the card does NOT gather.  It is here
                          so a card-side trace correlates with a host-side one
                          and a desynchronised sequence is detectable.
+0x08  u64   0            reserved, MUST be zero -- and IS checked
+0x10  i16 * n_embd       mantissas, little-endian
```

Logits block at `L_BASE`, stride `round_up(16 + 4*n_vocab, 64)` = **993,344 B**
at 248,320. One entry, or `N_STEP` entries with `CTRL.LOGITS_ALL`:

```
+0x00  i32   logit_exp    ONE shared exponent for the whole row
+0x04  i32   argmax       the card's own running argmax
+0x08  u64   0            reserved, MUST be zero
+0x10  i32 * n_vocab      logits
```

**One shared exponent is not a simplification, it is forced and it is already
relied on.** `matvec_core.vhd:959-961` gives `y_exp = w_exp + x_exp -
out_shift` in RAW `out_mode`, with no per-job term. That is exactly why the
lm_head's 15 row windows must run in RAW and why a plain signed int32 compare
is a correct argmax across all of them
(`docs/2026-08-28_token-io-path.md` section 7.1). In BFP mode the per-job
normalisation differs per window and there would be 15 different scales.

**Alignment is 64, not 4096.** These are not subsystem-A weight bases, whose
4096-byte alignment is `rtl/axi_rd_port.vhd`'s contract and is checked as
`ERR_ALIGN`. They are ordinary activation traffic, and 64 bytes is two 256-bit
AXI beats.

**Both blocks must lie wholly within ONE HBM stack.** A port on `SAXI_01..15`
reaches only `0x0_0000_0000..0x0_FFFF_FFFF` and one on `SAXI_17..31` only the
upper half, with no cross-stack path. `docs/2026-08-27_hbm-residency-map.md`
records that bytes in the wrong half are a **silent wrong answer** -- they read
back correctly over the host port and are wrong only when the engine's port
fetches them -- and asks in its own words for "an explicit host-side assertion,
not a comment". `fk33_seam_check_blocks()` is that assertion, and it runs at
`pl_open` before any DMA.

That check is not hypothetical. `docs/2026-08-28_token-io-path.md` section 7.3
records that the **shipped weight manifest already violates it**:
`blk.7.ffn_gate.weight` spans `4,267,130,880..4,295,446,528`, the stack
boundary is `4,294,967,296`, and its last 479,232 bytes are on the wrong side.
That is a live defect in the image, not in this seam, and it is why this check
exists.

---

## 6. What the seam deliberately does NOT do

- **It does not sample on the card.** `rtl/sampler_stream.vhd` exists, is
  verified, and its argmax is exposed as a fast path. The seam does not depend
  on it.
- **It does not batch.** `N_STEP > 1` is a prefill chunk of ONE sequence.
  Independent sequences need a KV partition concept the card does not have.
- **It does not carry the descriptor program.** `DESC_PTR` points at a program
  already resident in HBM. Emitting that program is OI-4 and nothing in any
  language does it yet.
- **It does not move weights.** Those are loaded once at cold start.
- **It does not gather the embedding.** `docs/2026-08-28_token-io-path.md`
  decides host-side gather on the **HBM port budget** -- A already takes 27 of
  the 30 engine ports -- not on latency, which is 6-35 us either way. The host
  side of that is a callback, `pl_embed_fn`, and the only implementation
  shipped is `pl_embed_synthetic`, which is a pure function of the token id and
  a model of nothing.

---

## 7. What has to exist before any of this runs

Ordered by who is blocked on whom.

| # | thing | owner | state |
|---|---|---|---|
| 1 | a bitstream that routes | TRACK CONGEST / OI-12 | route_design terminates, congestion level 7 |
| 2 | a `y` writeback path from A into an HBM region | `rtl/` | **absent.** Today A's only egress is `Y_IDX`/`Y_LO`/`Y_HI`/`Y_EXP`, one row per four BAR reads; 248,320 rows is 1.0-2.0 s per token |
| 3 | the seam register block, at a real BAR offset | `hw/fk33/gen_pcieep.py` | absent; offset PROPOSED here |
| 4 | a descriptor program emitter | OI-4, `tools/` | absent in every language |
| 5 | the embedding gather in C | backlog item 4 | absent; the interface is `pl_embed_fn` |
| 6 | a whole-model 9B numeric reference | backlog item 12, TRACK REF9B | in progress; the interface is `fk33_sim_opts.logits_fn` |
| 7 | a reconciliation of the residency map and the shipped manifest | -- | they disagree about the whole layout, and the shipped one straddles the stack line |

**Item 2 is the one that decides whether this seam is the right seam.** If a
`y`-to-HBM writeback is genuinely expensive in the fabric, the alternative is
argmax-only plus an on-card top-k, and the host loses `top_p`. Nothing measured
here can settle that; it is a fabric-area question.

**Item 6 is the one that decides whether any token is right.** The simulated
card is a plumbing double, not an oracle. When REF9B lands, giving
`logits_fn` a function that returns the reference logits for a
(position, token id) turns the whole host path into something with a numeric
claim. That connection is deliberately not made here, and making it is one
function.

---

## 8. The two implementations of the transport, and the swap

```
fk33_transport_open_chardev(user, h2c, c2h, allow_hw)   THE REAL CODE
fk33_transport_open_filedir(dir)                        the same code, on files
fk33_transport_open_sim(opts)                           a modelled card
```

The first two are ONE implementation. Pointing it at `/dev/xdma0_user` talks to
the card; pointing it at ordinary files talks to a file-backed image.
`hw/fk33/host/selftest_nocard.sh` already does exactly this substitution for
the bring-up program and this reuses that precedent. So "swap in the real
transport" is an argument change, not a code change.

**`fk33_transport_open_chardev()` refuses any path under `/dev/` unless the
caller passes `FK33_ALLOW_HARDWARE`, and nothing in this tree passes it** --
no test, no default, no environment variable, and `llama_server --card` accepts
only `sim` and `file`. It is a tripwire, not a security boundary; the boundary
is the operator. It exists because an agent destroyed this card's factory flash
image by crossing the hardware line.

---

## 9. NOT verified

- **Nothing has been run against the card.** Not one byte. No `/dev/xdma*` was
  opened, and `server/tests/seam_selftest.c` T12 exists to prove the code
  refuses to.
- **No token produced by any path here is inference.** The simulated card does
  not run a transformer.
- **The BAR offset, the register layout and the error codes are proposals.**
  The only file that can decide them is `hw/fk33/gen_pcieep.py`.
- **The per-transfer DMA latency is unmodelled**, so section 3 is an
  underestimate by an unknown amount.
- **The `x_exp` source is undecided.** `docs/2026-08-28_matvec-descriptor-format.md`
  section 8 notes A carries it in the descriptor extension AND exposes a port
  under `USE_XEXP_PORT`, and which the FK33 build uses is open. This seam puts
  it in the activation header, which is a third place; reconciling the three is
  an integration decision, not a host one.
- **`fk33_sim.c` does not model subsystem A.** The descriptor is checked for
  presence and alignment and is otherwise not executed. A's control plane
  already has a bit-exact bench; a second unverified C model of it here would
  be a competing claim, not a check.
