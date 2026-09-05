# Which composed timing numbers can actually be compared with each other?

Date: 2026-09-05. Prompted by discovering that a `KV_BLOCK` experiment committed
earlier the same day had changed five variables rather than one. If that error
was made once, the question is whether the existing record holds others.

## The question

> Of the composed-top routed WNS figures on record, which pairs differ in one
> variable, and which differ in ways nobody wrote down?

## The answer, up front

**None of them is a controlled pair. There is not one properly controlled
composed timing comparison in the record.** The four figures in circulation come
from at least three different netlists and at least three different directive
sets, and one of the four cannot be checked at all because its artifacts are
gone.

| run | routed WNS | LUT | **BRAM** | DSP | CLB | directives |
|---|---|---|---|---|---|---|
| `impl_pb` | **-0.402** | ? | **?** | ? | ? | all empty (per the Tcl's own note) |
| `wire4` | -0.502 | 266,138 | **327.5** | 2,177 | 50,055 | **not recorded** |
| `c4nd` | -0.422 | 263,544 | **253.5** | 2,177 | 49,620 | `''`/`ExtraNetDelay_high`/`AggressiveExplore`/`NoTimingRelaxation` |
| `c4kv4` | -1.542 | 248,727 | **253.5** | 1,953 | 46,706 | `ExploreWithRemap`/`ExtraTimingOpt`/`AggressiveExplore`/`Explore` |

**Read the BRAM column.** `wire4` carries **327.5 tiles** against `c4nd`'s
**253.5**. A 74-tile difference is not a placement effect and not a directive
effect: **it is a different design.** So the -0.502 against -0.422 comparison,
which reads as "these directives helped by 0.080 ns", compares two different
netlists.

**`impl_pb` is unrecoverable.** `sim/ooc_compose4_pnr.tcl:65` says:

> MEASURED with all four empty: routed core_clk WNS -0.402 (185.1 MHz) on the
> shipping config, `impl_pb`, 2026-09-04. **That is the baseline any directive
> run must be compared against.**

No `impl_pb` artifacts survive anywhere under the repo or the session scratch.
**The file instructs every future run to compare against a number whose netlist
can no longer be identified**, from a day before the tree changed. `c4nd`'s
-0.422 was called a loss against it; that verdict is not supportable, in either
direction.

**`c4nd` and `c4kv4` are the only pair sharing a netlist lineage** (same BRAM,
same day, same tree, synthesis hierarchies identical outside `c_attn` to the
digit) -- **and they differ in all four implementation directives.**

## The procedure

For each composed run, read its parameters from **its own recorded output**, not
from the intent in its launch script's comments:

1. `grep -hE '^C4_DIRECTIVES' impl.log` -- what was actually passed.
2. `grep -hE '^C4_UTIL <tag> routed' impl.log` -- the netlist fingerprint.
3. Compare **BRAM and DSP first**, not LUT. Both are hard blocks fixed at
   synthesis and unmoved by any implementation directive, so a difference in
   either proves a different netlist. LUT and CLB move with directives and
   cannot distinguish the two causes.

Step 3 is what makes this cheap. `wire4` vs `c4nd` differs by 74 BRAM tiles;
`c4nd` vs `c4kv4` matches at 253.5 and differs by exactly the 224 DSP that
`2 * G * KV_BLOCK` predicts. **One column separates "different design" from
"same design, different run".**

## Measured and REJECTED, do not retry

- **Do not compare `wire4`'s -0.502 with anything.** Different netlist, 327.5
  BRAM, and its directives were never recorded (it predates the instrumentation
  added 2026-09-04).
- **Do not use `impl_pb`'s -0.402 as a baseline**, despite the Tcl instructing
  it. The artifacts are gone and the netlist cannot be identified. The
  instruction should be amended rather than followed.
- **Do not conclude "directives lose" from -0.422 against -0.402.** That was two
  netlists of unknown relationship, and the difference claimed, 0.020 ns, is far
  below what a netlist change accounts for.

## Measurement traps hit

1. **The fingerprint was in every log the whole time.** `C4_UTIL ... routed`
   carries BRAM, DSP, LUT and CLB on one line, right beside the timing sentinel.
   Nothing had to be re-run to discover any of this. **The comparisons were made
   from the WNS alone**, because WNS is the number anyone cares about and it sits
   in a different sentinel from the evidence about whether it is comparable.
2. **A launch script's comment is not a parameter record.** `c4kv4`'s script
   states its directives are "the PRIOR BEST ... so the comparison is against a
   recorded number" -- and it was then compared against a *different* recorded
   number taken with different directives. The comment was true about intent and
   useless as evidence.
3. **The tag in the sentinel is not the directory name.** The run in
   `scratchpad/c4wire/` writes `C4_UTIL wire4 ...`. Any script keying off the
   directory name to find a run's own rows finds nothing and reports an empty
   result rather than an error, which is the recorded silent-empty-filter shape.

## What to change

**The fix is one line of Tcl, not a discipline.** `ooc_compose4_pnr.tcl` already
computes everything needed; it should emit the netlist fingerprint **on the same
line as the timing verdict**, so that a comparison is a single grep and an
incomparable pair is visible without a second lookup:

```
C4_TIMING wns=-0.422 whs=0.009 bram=253.5 dsp=2177 lut=263544 dirs='|ExtraNetDelay_high|AggressiveExplore|NoTimingRelaxation'
```

Deliberately NOT done while `c4kv4c` is running, per the recorded rule that
editing a runner mid-run invalidates the run. To be applied after it lands.

The Tcl's `impl_pb` baseline note should also be amended to say the artifacts are
gone, rather than continuing to direct comparisons against them.

## Open, not yet answered

- **What the composed design's real baseline WNS is**, with all directives empty,
  on the current tree. No surviving run establishes it. Everything called a
  "baseline" here is either a different netlist or unrecoverable.
- Whether directives help or hurt this design at all. The only evidence was the
  -0.402/-0.422 pair, which is now withdrawn as incomparable.
- `c4nd` vs `c4kv4c`, running now, will be **the first controlled composed
  comparison in the project's history**: same tree, same synthesis DCP lineage,
  identical directives, differing only in `KV_BLOCK`.
