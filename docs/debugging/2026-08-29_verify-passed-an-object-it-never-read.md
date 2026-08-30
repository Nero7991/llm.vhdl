# `--headers-only` called an object PASS that neither check ever read

**Date:** 2026-08-29
**Who:** dispatcher (not a subagent; this touched the live card, which
subagents may never do)
**Tree:** `fpga` branch, HEAD `5a19f98` at the start, committed at `4b26b7e`.
**Hardware:** FK33 card 1, endpoint `06:00.0`, `xdma` loaded (refcount 1),
`/dev/xdma*` nodes from 15:12. Oren authorised load-and-run on card 1 for
2026-08-29. VCCINT untouched, no flash write, card 2 never addressed.
**Tools:** `hw/fk33/host/fk33_load_weights.py`, `sg fk33 -c`, `python3`.

---

## 1. The question, verbatim

> Is the 9B weight image still resident on card 1?

## 2. The answer, up front

**Yes, and completely: 4,488,462,336 bytes read back in 5.72 s at 0.78 GB/s,
249 headers plus 250 payload digests, all matching.**

**But the fast check I reached for first said PASS while leaving one object
unread, and it had been doing so all along.** `verify --headers-only` reported
`250 objects` in and `249 headers parsed and matched`, then printed
`PASS  the image on the card is the image the manifest describes`. The missing
object is `nonmatvec_f32.bin` (kind `f32blob`, 4,571,136 bytes at
`0x10bbaa000`) -- the norms and biases, i.e. precisely the class whose
corruption yields subtly wrong logits rather than obvious garbage.

Two guards were skipping it in opposite directions:

- check 1 is gated `if e["kind"] == "mv4i":`, because only an mv4i object has a
  parseable header, so a `f32blob` never reaches it;
- check 2 opened with `if headers_only: continue`, so it never reached that
  either.

It fell through both and was counted in neither tally. `249` against `250`
reads as a rounding detail, which is why it survived.

## 3. The procedure

Each step isolates one thing; the point of the order is that the cheap check
came first and was the one that lied.

1. **Read-only card state** -- `lspci -d 10ee:`, `lsmod | grep xdma`,
   `ls /dev/xdma*`. Establishes the card is up and the driver bound before any
   claim about contents. Controls for "the image is gone" vs "the path to it is
   gone", which look identical from a failed read.
2. **`id -nG` vs `getent group fk33`.** The process was NOT in `fk33`; the
   account WAS. Group membership is read at login. `sg fk33 -c` bridges it
   without re-login. Skipping this reads as a permissions fault on the card.
3. **`verify --headers-only`** -- the fast residency check. PASS, 249/250.
4. **Counted the manifest by kind** -- `249 mv4i`, `1 f32blob`. This is what
   turned "249 is odd" into a named object.
5. **`verify --only nonmatvec`** (full digest, 4.5 MB, 0.01 s) -- PASS. So the
   image was fine; the CHECKER was not.
6. **Fixed, then teeth-checked with three manifests** before believing the fix.
7. **Full read-back of all 250 objects** as the independent confirmation.

## 4. The evidence, raw

Before the fix:

```
verifying 250 objects against the manifest (headers only), C2H /dev/xdma0_c2h_0
read 1,019,904 bytes in 0.00 s = 0.21 GB/s
249 headers parsed and matched, 0 payload digests matched
PASS  the image on the card is the image the manifest describes
```

The object nobody looked at:

```
total objects: 250
by kind: {'mv4i': 249, 'f32blob': 1}
UNCHECKED in headers-only: nonmatvec_f32.bin kind= f32blob nbytes= 4571136 hbm_offset= 0x10bbaa000
```

After the fix, same command:

```
read 5,591,040 bytes in 0.01 s = 0.54 GB/s
249 headers parsed and matched, 1 payload digests matched
PASS  the image on the card is the image the manifest describes (250 of 250 objects read and checked)
```

Cost of closing the hole: 1,019,904 -> 5,591,040 bytes, and 0.00 s -> 0.01 s.

Full read-back:

```
verifying 250 objects against the manifest (full read-back), C2H /dev/xdma0_c2h_0
read 4,488,462,336 bytes in 5.72 s = 0.78 GB/s
249 headers parsed and matched, 250 payload digests matched
PASS  the image on the card is the image the manifest describes (250 of 250 objects read and checked)
```

### Teeth table

| # | mutation | verdict | note |
|---|---|---|---|
| T1 | `f32blob` base moved one 4 KB page | **FAIL**, digest mismatch named | proves the blob is genuinely read now |
| T2 | `kind` renamed to `somethingelse` | **PASS**, 250/250 | **does NOT bite, and should not** -- an unknown kind falls through to the digest rather than being skipped, which is the intent |
| T3 | untouched control | **PASS**, 250/250 | the check can still say yes |
| T4 | an object read by neither check | **could not construct** | see section 6 |

## 5. Measured and REJECTED -- do not retry

- **`fk33ctl.py verify` as the residency check.** It compares HBM against the
  SOURCE FILE, so loading the right bytes to the wrong base passes. The loader's
  own header documents this; it is why `fk33_load_weights.py verify` exists and
  opens no `.mv4i` file at all. Do not "simplify" by merging them.
- **Counting successes as coverage.** My first fix summed `nhdr + nhash` and
  refused when it fell short of the object count. T1 then reported a genuine
  wrong-offset fault as *"a hole in the CHECKER, not necessarily a fault in the
  image"* -- exactly backwards, and it swallowed the real FAIL line, because a
  digest MISMATCH leaves `nhash` un-incremented and so is indistinguishable
  from never having looked. Coverage must count what was ATTEMPTED, and a real
  fault must be reported before any coverage complaint.

## 6. Measurement traps hit, including my own

- **I introduced a defect in the fix for a defect, and only the teeth-check
  caught it.** Both my reasoning and the passing control said the first version
  was right. See the second bullet above.
- **The `UNVERIFIED` branch is currently UNREACHABLE.** Every path now marks
  `attempted`. I could not construct T4 and have labelled the branch in the
  source as unproven rather than presenting it as a working check. It is kept
  as defence against a future `kind` whose handling `continue`s past both
  checks -- the exact shape of the bug this block exists to prevent.
- **`id -nG` describes the PROCESS, `getent group` the ACCOUNT.** Group
  membership is read at login, so a freshly-granted group is absent from a
  long-lived shell and the symptom is a permissions error on the card.
- **The fast check is the one that lied.** Reaching for `--headers-only` first
  is right on cost and is exactly why the hole survived: it is the mode nobody
  re-reads because it always passes.

## 7. Open, not yet answered

- **Whether any other checker in `hw/fk33/host/` has the same shape** -- a
  per-kind or per-mode guard that skips an object while the summary still says
  PASS. Not audited. `fk33ctl.py` in particular was not examined.
- **What the 249th header's absence would have cost in practice.** The blob was
  intact, so this is a near-miss with no measured consequence, and I have not
  established whether a corrupted `nonmatvec_f32.bin` would have been caught
  downstream by anything else.
- **The image is verified as BYTES, not as VALUES.** That it matches the
  manifest says nothing about whether the packer produced the right numbers.
