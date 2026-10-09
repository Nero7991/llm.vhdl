# Jungle Cat 27B silicon runbook (plan Task 12, steps 3, 4 and 6)

Plan: `docs/superpowers/plans/2026-10-07-jc-engine-composition.md`, Task 12. Spec:
`docs/superpowers/specs/2026-10-07-jc-engine-composition-design.md` sections 5 and 7.
Bitstream: `hw/jc/card/results/jccard8_2026-10-09/jc_card.bit` (125 MHz `clk_core`,
`xcvu35p-fsvh2104-2L-e`). Written 2026-10-09 without touching the board: every command
below that reaches the BMC is for the main session or Oren only.

**MAIN SESSION ONLY. Every step marked [BOARD] opens the Jungle Cat's JTAG through the BMC.**

## 0. What this runbook found before it could be written (read first)

These change Task 12 as written. Each is cited; what is still open is in section 7.

1. **CLOSED 2026-10-09: `run_prompt --jc SOCK --jc-die D [--jc-die2 D2]`.** The flags set
   `o.transport = PL_TRANSPORT_JC`, `o.jc_sock`, `o.jc_die` and the second card's
   `o2.jc_die` (`server/pl_backend.h:115-120`); both cards share the broker's one
   connection (`fk33_transport_jc.c`, I3). They are refused, before any socket is opened,
   without `--jc-die`, without `--v2`, with `--allow-hardware`/`--dev`/`--dev2`/
   `--teeth-argmax`, with `--jc-die2` but no second card, with a second card but no
   `--jc-die2`, and with the same die twice. Tested against a fake broker whose dies are
   the simulated seam (`server/tests/jc_sim_broker.c`, `server/tests/test_run_prompt_jc.py`,
   `make -C server test_run_prompt_jc`): the ids over `--jc` equal the ids from the same
   sim driven directly, and the broker's log shows card 0's program on `--jc-die` and
   card 1's on `--jc-die2` (a mutant routing card 1 to card 0's die fails 3 cases).
2. **The JC transport refuses every HBM write, and that stays (DECIDED 2026-10-09).**
   `mem_write` returns `-EPERM` (`server/fk33_transport_jc.c`). The spec forbids the
   alternative: "HBM writes stay with the USER4 loader alone; the C transport's
   `mem_write` returns `-EPERM`" (`docs/superpowers/specs/2026-10-07-jc-engine-composition-design.md`,
   "CORRECTION 2026-10-07 (second): the control core needs a read-only HBM master"; and
   section 4: "The broker and `coe_load.py` are separate lanes and never hold the BMC at
   once"). The RTL agrees, so it is not only policy: the control core's `WR_INC`/`WR_FIX`
   ops are AXI-Lite (`m_axil_*`) register writes, and its HBM master `m_axi_*` is AXI4
   READ-ONLY, AR and R channels only, op `MEM_RD` (`hw/jc/ctl/README.md:38-41`,
   `rtl/jc_ctl_pkg.vhd:19-24`; no `m_axi_aw*`/`m_axi_w*` in `rtl/jc_ctl_exec.vhd`).
   So the three things the FK33 writes by DMA (`hw/fk33/host/fk33_chat2.sh:128-136`: the
   descriptor arena, the GDN state zero, and at load time the image record) go in through
   `coe_load.py load` with the broker stopped:
   - once per session, all three: the side image `side.json` from
     `hw/jc/host/jc_side_image.py` (3.2, 3.3);
   - before every later sequence, the GDN zero alone: `side_gdn.json`, through
     `hw/jc/host/jc_bc_lane.sh rezero` (item 8, section 6).
   Activations are NOT affected: a v2 seam takes X through window 2 and returns R_X
   through window 3 (`pl_backend.c:1275-1290`, `pl_backend.c:1467-1483`), and the
   `--jc` test above runs a whole v2 prefill and decode with no `mem_write` call.
3. **There is no seam window 4.** `rtl/fk33_seam.vhd:609` declares `r_win_sel` 2 bits wide
   (windows 0..3; `server/fk33_seam.h:381-384`). The utilisation counters landed in the
   ENGINE's AXI-Lite map instead (commit `6ed5f193`, "read through the engine's AXI-Lite
   map"): `UTIL_SEL 0x12040`, `UTIL_DATA 0x12044`, `UTIL_CLR 0x12048`
   (`hw/fk33/host/fk33_regs.h:129-131`, semantics `rtl/matvec_int4_desc_axi.vhd:80-96`),
   which the ctl core's AXI-Lite master reaches at `0x12000`
   (`hw/jc/card/jc_card_bd.tcl:839`). Step 6 reads them with `hw/jc/host/jc_seam.py util`.
4. **The broker needs `--manifest` for both dies**, or `pl_open` fails: `pl_open` reads the
   image record with `mem_read` (`pl_backend.c:607`) and the broker refuses every `memrd`
   on a die with no manifest unless `--allow-image-read` (`tools/jc/jc_broker.py:124-128`,
   `ImageFence.check` at `jc_broker.py:242-251`). `load_fence` reads only the manifest JSON
   (`jc_broker.py:254-268`), so the JSON alone is enough on the BC-250. The invocation
   (3.4 runs it through `hw/jc/host/jc_bc_lane.sh start`):

   ```
   python3 tools/jc/jc_broker.py serve --bmc $BMC --chain AB --dies ~/jc_dies.json \
       --sock $BCW/broker.sock \
       --manifest A=~/jc_models/qwen38-27b-card0-b0-32/manifest.json \
       --manifest B=~/jc_models/qwen38-27b-card1-b33-63/manifest.json
   ```

   `--manifest` takes `DIE=PATH`, once per die (`jc_broker.py:1096-1100, 1113-1114`).
   They must be the manifests `coe_load.py load` used for the resident images.
5. **Where `pl_pipeline` runs.** `run_prompt` links `pl_pipeline.c` and `pl_backend.c`, and
   the transport is `connect()` on an `AF_UNIX` socket (`fk33_transport_jc.c:969`): it must
   run where the broker's socket file is. The broker must run on the BC-250 (it reaches the
   BMC). This runbook runs `run_prompt` on the WORKSTATION (model files, `server/run_prompt`
   and llama.cpp are all here) through an ssh Unix-socket forward (step 3.4). The other
   option, building and running `run_prompt` on the BC-250, needs the token embedding
   (715 MB) and both manifests there, which this runbook did not verify.
6. **The broker serves one client** (`jc_broker.py:16-17`). `run_prompt` holds the socket
   for its whole run; `jc_seam.py` runs only before or after it, never during.
7. **jccard8 is timed at 0.85 V VCCINT only** (`hw/jc/card/results/jccard8_2026-10-09/README.md`,
   last paragraph). Confirm the rail before step 4; changing it is Oren's call.
8. **The GDN state is re-zeroed before every sequence, as on the FK33 (gap 4, 2026-10-09).**
   The FK33 host zeroes the whole `hbm.gdn_state_bytes` at `hbm.gdn_state_base` before EVERY
   question: `hw/fk33/host/fk33_chat.sh:168-173` ("Zero the GDN recurrent state (every
   layer), so this question starts clean") and `fk33_chat2.sh:131-135` on both cards.
   `fk33_ctxtest.sh` runs one `fk33_chat2.sh` per run (`fk33_ctxtest.sh:53`) and
   `server/llmvhdl_server.py` one per question (`llmvhdl_server.py:64`), so every FK33
   sequence starts from a zeroed region. That region holds the recurrent mantissas, their
   exponents and the conv-tap reservation (`tools/hbm_map.py:437-439`). `run_prompt
   --seq-reset` clears only the seam's and engine's positions, and `server/pl_pipeline.c`
   does no state handling at all. The JC now does the same as the FK33:
   `hw/jc/host/jc_ctxtest.sh` runs `hw/jc/host/jc_bc_lane.sh rezero` before every run by
   default (`JC_NO_REZERO=1` is the only way to skip it), and section 6 says so. Whether the
   zero is NEEDED (B masks the recurrent read at `tk0`, `rtl/gdn_recur_pipe.vhd:592`;
   `gdn_conv` zeroes invalid taps, `rtl/gdn_conv.vhd:307-314`) does not decide it: the FK33
   flow that passed its context tests zeroed, so the JC zeroes.

## 1. Variables (set once per shell; never committed)

Workstation (WS):

```bash
export REPO=/home/orencollaco/GitHub/llama.vhdl
export BC='<user>@<bc250 address>'     # resolve per CLAUDE.md "The second machine" (DHCP lease)
export BMC='<bmc address>'             # the board BMC; never written to the repo
export W=/mnt/storage/fk33_builds/jc27b_silicon_2026-10-09    # NOT /tmp (CLAUDE.md HOUSE STYLE)
export BCW=/home/orencollaco/jc27b_run  # an absolute, non-/tmp work dir on the BC-250
export M=/mnt/storage/llama-models
export MAN0=$M/qwen38-27b-card0-b0-32/manifest.json   # die A: blocks 0..32, no LM head
export MAN1=$M/qwen38-27b-card1-b33-63/manifest.json  # die B: blocks 33..63 + LM head
export BC_MAN0='~/jc_models/qwen38-27b-card0-b0-32/manifest.json'   # on the BC-250; die A
export BC_MAN1='~/jc_models/qwen38-27b-card1-b33-63/manifest.json'  # on the BC-250; die B
# hw/jc/host/jc_bc_lane.sh (3.4, section 6) reads these names; a leading ~/ is the BC-250's $HOME
export JC_BC=$BC JC_BMC=$BMC JC_BCW=$BCW JC_BC_MAN0=$BC_MAN0 JC_BC_MAN1=$BC_MAN1
export EMB=$M/qwen38-27b-mv4i/token_embd.weight.mv4i
export QTK=$REPO/build_artifacts_tok/qwen35_9b.qtk
export PROMPT=$REPO/hw/fk33/results/goal_dcdc_2026-09-17/prompt_tokens.txt
export SOCK=$W/broker.sock               # the forwarded socket as the WS sees it
mkdir -p $W/card0 $W/card1
```

`QTK` is the 9B tokenizer on purpose: the 27B GGUF's tokenizer has the same 248,320 tokens
and 247,587 merges, hash-identical to the 9B GGUF's (MEASURED 2026-10-09, gguf-py over
`tokenizer.ggml.tokens`/`.merges` of both files; `pre` = `qwen35` in both).

**The reference prompt** is `hw/fk33/results/goal_dcdc_2026-09-17/prompt_tokens.txt`: the
23 ids of "In what cases is DC-DC converters better than transformers" through the chat
template, thinking off, `parse_special = 1` (that directory's README). It is given to the
card AND to llama.cpp as IDS, never as text: `llama-completion -f` on the same text gives 31
ids, a different input (same README, "the trap on the way"). The 9B card's first token on
it was 1206, equal to the 9B reference (`docs/worklog/WORKLOG-through-2026-10-05.md:1612`).

**The 27B GGUF** is `/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf` (18,973,870,432 B):
both manifests' `source_gguf` and `hbm.gdn_const_source_gguf` name it.

## 2. Preconditions (checked, not assumed)

| # | host | check | gate |
|---|---|---|---|
| P1 | BC | Task 12 steps 1-2 done: jccard8 on both dies, both 27B images `JCVERIFY_PASS` | the main session's own step-2 log |
| P2 | BC | nothing else holds the BMC: no `sqrl_bridge`, `coe_load.py`, `coe_soak.py`, `jc_telemetry.py`, other broker | identify by `/proc/PID/exe` + `cwd`, never `pgrep -f` (CLAUDE.md) |
| P3 | WS | `make -C $REPO/server run_prompt` | exit 0 (MEASURED 2026-10-09: builds) |
| P4 | WS | `$REPO/server/run_prompt --help 2>&1 \| grep -qE -- '--jc[ ]'` | exit 0 (MEASURED 2026-10-09, after the `--jc` patch) |
| P6 | WS | `make -C $REPO/server test_run_prompt_jc` | `16 passed` (no board: fake broker over the sim) |
| P7 | BC | `ls ~/jc_models/qwen38-27b-card0-b0-32/manifest.json ~/jc_models/qwen38-27b-card1-b33-63/manifest.json ~/jc_dies.json` | all three exist (not verified from the WS) |
| P5 | WS+BC | `bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` | `done` |

## 3. Step 3: broker, bring-up, seam ID, CAPS, image record

### 3.1 [WS] token programs, one per die (host only)

```bash
cd $REPO
python3 tools/gen_layer_program.py --token --shape 27b --manifest $MAN0 --blocks-range 0:32 \
    --no-lmhead --x-exp 0 --d-table $W/card0/token.dtbl --rel-file $W/card0/token.rel \
    --arena-image $W/card0/token.arena > $W/card0/gen.log 2>&1; echo rc=$?
python3 tools/gen_layer_program.py --token --shape 27b --manifest $MAN1 --blocks-range 33:63 \
    --pad-norms 66 --x-exp 0 --d-table $W/card1/token.dtbl --rel-file $W/card1/token.rel \
    --arena-image $W/card1/token.arena > $W/card1/gen.log 2>&1; echo rc=$?
grep -E '^A arena image' $W/card0/gen.log $W/card1/gen.log
```

- Flags: `--shape 27b` (`tools/gen_layer_program.py:1178`); `--blocks-range`, `--no-lmhead`,
  `--pad-norms 2*lo` exactly as `hw/fk33/host/fk33_chat2.sh:113-124` builds them (pad on by
  default there, `FK33_PAD_NORMS=1`); block ranges from the manifests' own file lists.
- Gate: `rc=0` twice and `^A arena image` per die. MEASURED 2026-10-09 in a scratch dir:
  die A `306 descriptors x 512 B stride = 156672 B; load at HBM 0x1FF9B8000`, die B
  `302 descriptors ... 154624 B`, the second also printing `PAD NORMS 66`. 12.8 s and
  31 MB RSS per die.
- Failure: a nonzero rc with the reason in `gen.log` (a manifest/shape cross-check).

### 3.2 [WS] the side images (host only)

```bash
python3 $REPO/hw/jc/host/jc_side_image.py $MAN0 $W/card0
python3 $REPO/hw/jc/host/jc_side_image.py $MAN1 $W/card1
```

- Gate: two `^SIDE_OK .*/side\.json ` and two `^SIDE_OK .*/side_gdn\.json ` lines. MEASURED
  2026-10-09 (scratch): `token.arena@0x1ff9b8000+156672 gdn_zero.bin@0x1d0000000+78741504
  imglock.bin@0x1ffa03e00+512`, 39,772 frames, 0.75 s, 94 MB RSS.
- The image record claims the WHOLE image is resident. It is only true because P1 passed
  `JCVERIFY_PASS`; never load `side.json` onto a die whose image did not verify.
- Failure: a Python exception (`PlanError` from `coe_load.plan_frames`, or the
  "arena would overwrite the image record" assertion).

### 3.3 [WS -> BC, then BC, BOARD] load the side images, one die at a time, broker NOT running

```bash
rsync -a $W/card0/ $BC:$BCW/card0/ && rsync -a $W/card1/ $BC:$BCW/card1/
ssh "$BC" 'bash -s' <<EOF
set -uo pipefail
cd /home/orencollaco/GitHub/llama.vhdl
for c in 0:A 1:B; do
  d=\${c#*:}; n=\${c%%:*}
  python3 tools/jc/coe_load.py load $BCW/card\$n/side.json --bmc $BMC --chain AB --die \$d \
      --dies \$HOME/jc_dies.json > $BCW/side_load_\$d.log 2>&1
  python3 tools/jc/coe_load.py verify $BCW/card\$n/side.json --bmc $BMC --chain AB --die \$d \
      --dies \$HOME/jc_dies.json > $BCW/side_verify_\$d.log 2>&1
  grep -hE '^(JCLOAD_|JCVERIFY_)' $BCW/side_load_\$d.log $BCW/side_verify_\$d.log
done
EOF
```

- Flags: `load`/`verify MANIFEST --bmc --die --chain --dies` (`tools/jc/coe_load.py:3-7`,
  parser `coe_load.py:1486-1533`); `--hz` defaults to 27 MHz (`coe_load.py:1439`). The side
  manifest is a `files` list of flat entries, which `coe_load._entries` and
  `fk33_load_weights.pieces_of` take as one piece each (`coe_load.py:159-160`,
  `tools/hbm_map.py:761-765`).
- Gate, per die: `^JCLOAD_DONE ` then `^JCVERIFY_PASS 3 pieces, 0 bad`
  (`coe_load.py:1595`, `coe_load.py:1621`).
- Duration, ESTIMATE: 78.9 MB at the MEASURED ~2.6 MB/s = ~31 s per die plus identify and
  range CRCs, about 45 s per die; under the BMC's ~290 s connection life, so no `--resume`.
- Failure: `^JCLOAD_ABORT ` (`coe_load.py:1563-1613`; a DNA mismatch names the die record),
  or `^JCVERIFY_FAIL`. A connection drop prints `JCLOAD_ABORT connection lost`; rerun with
  `--resume`.

### 3.4 [BC, BOARD] start the broker; [WS] forward its socket

```bash
bash $REPO/hw/jc/host/jc_bc_lane.sh start --dry-run    # prints the remote script, runs nothing
bash $REPO/hw/jc/host/jc_bc_lane.sh start | tee $W/lane_start.log
grep -qE '^JCLANE_DONE start$' $W/lane_start.log && echo LANE_OK
ssh -f -N -M -S $W/fwd.ctl -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
    -L $SOCK:$BCW/broker.sock "$BC" && test -S $SOCK && echo FWD_OK
```

- `jc_bc_lane.sh start` runs, on the BC-250 under `bash -s`, section 0 item 4's `serve`
  line with `--manifest A=$BC_MAN0 --manifest B=$BC_MAN1` (dies from `JC_DIE0/1`, default
  A/B), writes `$BCW/broker.pid`, and waits for `^JCBROKER_(READY|ABORT)` in
  `$BCW/broker.out`. It refuses to start a second broker (the pid file is checked by
  `/proc/PID/exe` and `/proc/PID/cwd`, never by command line). Tested dry and against
  stubs, no ssh: `hw/jc/host/test_jc_bc_lane.py`.
- Flags: `serve --bmc --chain --dies --sock [--hz] [--reconnect-secs] [--manifest DIE=PATH]
  [--allow-image-read]` (`tools/jc/jc_broker.py:1106-1115`). It never passes
  `--allow-image-read`: the fence is what keeps a stray `memrd` off the weights.
- Gate: `LANE_OK` (`^JCLANE_DONE start`, printed only after `^JCBROKER_READY ` appeared in
  `broker.out`, `jc_broker.py:1131`), then `FWD_OK`.
  READY means the socket is bound; it does NOT mean the dies were identified: identity
  runs at the first request to each die (`jc_broker.py:456-462`), i.e. in 3.5.
- Duration: ~1-2 s to READY (no board traffic before the first request).
- Failure: `^JCBROKER_ABORT ` (`jc_broker.py:1129`: a bad die record, a manifest that
  does not parse, "another broker is serving", `jc_broker.py:1069-1093`). In
  `broker.err` later: `JCBROKER_HALT` (`jc_broker.py:420`: a DNA mismatch or a guard
  refusal; every later request is refused until restart), `JCBROKER_UNKNOWN die`
  (`jc_broker.py:428`: a window's state is unknown), `JCBROKER_RECONNECT` (normal, every
  ~270 s, `jc_broker.py:407`).
- Stop (end of session): `ssh -S $W/fwd.ctl -O exit "$BC"`, then
  `bash $REPO/hw/jc/host/jc_bc_lane.sh stop` (SIGINT to the pid in `$BCW/broker.pid`, which
  runs the clean close, `jc_broker.py:1132-1141`; gate `^JCLANE_DONE stop`).

### 3.5 [WS, BOARD] seam ID, CAPS and the image record on both dies

```bash
python3 $REPO/hw/jc/host/jc_seam.py status --sock $SOCK
for d in A B; do m=$([ $d = A ] && echo $MAN0 || echo $MAN1)
  python3 $REPO/hw/jc/host/jc_seam.py seam --sock $SOCK --die $d --manifest $m | tee $W/seam_pre_$d.txt
done
grep -HE '^seam id    0x4c4c4d32|^caps |^cap flags|^status .* err=0|^ +MATCH ' $W/seam_pre_?.txt
```

- `jc_seam.py seam` is `hw/fk33/host/fk33ctl.py`'s `seam` report unchanged
  (`fk33ctl.py:593-797`), its reads sent as broker `rd32` and its record read as `memrd`.
  Offsets: ID 0xE000, VERSION 0xE004, CAPS_VOCAB/EMBD/CTX 0xE008-0xE010, STATUS 0xE018,
  CAPS_FLAGS 0xE04C (`server/fk33_seam.h:232-239`, `:301`).
- Gate, per die (all five): `^JCSEAM_STATUS ok`; `^seam id    0x4c4c4d32`; a `^caps ` line
  (expect `n_vocab 248320  n_embd 5120`); `^cap flags` with bits 0, 4, 5, 6 and 7 set
  (WINDOWS, SEQ_RESET, KV_BASE, XEXP_OUT, NORM_HBM; `fk33_seam.h:392-405`; the pipeline
  refuses a die without XEXP_OUT, `fk33_chat2.sh:16-17`); `^status .* err=0`; and
  `^ +MATCH <manifest> describes the resident image` (`fk33ctl.py:576-578`).
- EXPECTED, not a fault: `MISMATCH n_embd`/`MISMATCH n_layer` lines and a
  `SEAM n problem(s)` tail, because fk33ctl compares CAPS with the 9B
  (`fk33ctl.py:634-641`).
- Duration, ESTIMATE: the first request per die runs the USER4 identify (a few s); then
  ~30 register reads at ~3 ms each (1.15-1.36 ms per unpipelined BMC shift, MEASURED,
  `docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md:227-231`, at least two
  shifts per read). Under 20 s per die.
- Failure: `seam id` reading 0xFFFFFFFF or 0 (the dead-bus words, `fk33ctl.py:610-620`);
  `JCSEAM_ERROR BrokerError: Halted...` (the die's DNA is not the record's: wrong chain
  or wrong `--dies`); `image NO RECORD` (3.3 did not land); `MISMATCH ... is NOT the
  resident image` (STOP: driving it programs a wrong KV base, `pl_backend.c:560-575`).

## 4. Step 4: first token for the reference prompt

### 4.1 [WS, BOARD] clear the counters, then the token

```bash
for d in A B; do python3 $REPO/hw/jc/host/jc_seam.py util-clear --sock $SOCK --die $d; done
/usr/bin/time -v $REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B --seq-reset --v2 \
    --dtbl $W/card0/token.dtbl --rel $W/card0/token.rel \
    --dtbl2 $W/card1/token.dtbl --rel2 $W/card1/token.rel \
    --manifest $MAN0 --manifest2 $MAN1 --prompt $PROMPT --qtk $QTK --mv4i $EMB \
    --max-new 1 --ids-out $W/first_token.ids > $W/first_token.out 2> $W/first_token.err
echo rc=$?; grep -E '^(transport|transport2|card|card2|pipeline|seq-reset|prefill|decode|timing) ' $W/first_token.out
grep -E 'image lock OK' $W/first_token.err
```

- Flags: `--jc/--jc-die/--jc-die2` select the JC transport (section 0 item 1); the rest
  are passed in the order `fk33_chat2.sh:143-148` passes them. `--max-new 1` makes the run
  prefill only: 23 GOs per die, one argmax. The GDN state is the zero 3.3 loaded: nothing
  between 3.3 and here runs a GO (3.5 only reads).
- Gate: `rc=0`; `^transport  JC broker <SOCK> die A` and `^transport2 JC broker <SOCK> die B`;
  `^seq-reset  seam AND engine positions cleared`;
  `^prefill +23 ids, pos 23, first argmax [0-9]+` (`run_prompt.c:704`); `image lock OK`
  twice on stderr (`pl_backend.c:641`). The first-token argmax is the number after
  `first argmax`; it must equal `REF_ARGMAX` from 4.2.
- Duration, ESTIMATE: every token carries R_X from die A to die B as 5,120 `rd32`s of
  window 3 (`pl_backend.c:1475-1479`, `pl_pipeline.c:141-153`), uncoalesced on purpose
  (`fk33_transport_jc.c:81`, "READS ARE STILL NEVER COALESCED"). At ~3 ms per read that is
  ~15 s per position, so ~6 min for the 23-id prefill, plus `pl_open` (descriptor program
  coalesced into `wrn`s, seconds). The GO timeout is 60 s per GO (`pl_backend.c:21`) and
  the socket reply timeout 120 s (`FK33_JC_TIMEOUT_MS`, `fk33_transport_jc.c:132-133`).
- Failure: `pl_open refused` (stderr names it: no record, record mismatch, CAPS);
  `prefill` missing with `run_prompt: prefill ... (WDOG ...)` (a unit hung; dump both seams
  at once with 3.5 BEFORE anything else); `-ETIMEDOUT`/`-ECONNABORTED` from the transport
  (broker hung or halted: read `broker.err`); `NOTE the card's n_vocab ... disagree`.

### 4.2 [WS] CPU reference: llama.cpp, same GGUF, same 23 ids, greedy (main session's call)

Binary: `~/GitHub/llama.cpp.upstream/build/bin/llama-server` (build of 2026-06-26, links
`libllama.so.0.0.9820`, has `llama_model_qwen35`). The ids go through `/completion` with
`"prompt": [ids]`, exactly how the 9B reference was made
(`hw/fk33/results/goal_dcdc_2026-09-17/README.md`); `--device none -ngl 0` keeps it on the CPU.

```bash
cd ~/GitHub/llama.cpp.upstream/build/bin
./llama-server -m /mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf --device none -ngl 0 \
    -c 512 -np 1 -t 24 --no-warmup --host 127.0.0.1 --port 18087 > $W/ref_server.log 2>&1 &
echo $! > $W/ref_server.pid
until curl -sf http://127.0.0.1:18087/health > /dev/null; do sleep 2; done
IDS=$(tr -s ' \n' ',' < $PROMPT | sed 's/,$//')
curl -s http://127.0.0.1:18087/completion -d "{\"prompt\":[$IDS],\"n_predict\":1,\"temperature\":0,\"top_k\":1,\"n_probs\":5,\"return_tokens\":true,\"cache_prompt\":false}" \
    > $W/ref_first_token.json
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print('REF_ARGMAX', r['tokens'][0]); print('REF_TOP', json.dumps(r.get('completion_probabilities', [])[:1]))" $W/ref_first_token.json
kill $(cat $W/ref_server.pid)
grep -E 'prompt eval|n_prompt_tokens|23 tokens' $W/ref_server.log | tail -3
```

- Gate: `^REF_ARGMAX [0-9]+`, and the server log's prompt token count is 23 (a different
  count means the ids did not go in as ids).
- RAM, ESTIMATE: ~20 GB resident (the 18.97 GB GGUF mmapped, plus a 512-token KV and
  recurrent state well under 1 GB). The box has 31 GiB: production `llama-server` must
  stay stopped and NO Vivado may run beside it (CLAUDE.md memory budget).
- Time, ESTIMATE: 20-60 s to map the GGUF from NVMe, a few seconds for 23 positions of a
  27B Q4_K_M on 24 threads; about 1-2 minutes in all.
- Caveat on the comparison: the card's weights were packed from this same GGUF
  (`source_gguf`), but its arithmetic is INT4 with block-float activations, not ggml's.
  Agreement on argmax is the Task 12 gate; a mismatch on a small top-1 margin is a
  question for a logit-level comparison, which the v2 seam cannot answer (it publishes
  no logits row, `run_prompt.c:634-640`). Record `REF_TOP`'s top-5 so the margin is known.

## 5. Step 6: utilisation and token time (right after 4.1, before anything else runs)

```bash
for d in A B; do m=$([ $d = A ] && echo $MAN0 || echo $MAN1)
  python3 $REPO/hw/jc/host/jc_seam.py util --sock $SOCK --die $d | tee $W/util_$d.txt
  python3 $REPO/hw/jc/host/jc_seam.py seam --sock $SOCK --die $d --manifest $m > $W/seam_post_$d.txt
done
grep -hE '^JCUTIL die .* jobcyc|^JCUTIL_SUMMARY' $W/util_?.txt
grep -HE '^last job|^status ' $W/seam_post_?.txt
grep -E '^timing ' $W/first_token.out
```

- What it reads: per die, ENG_ID (0x12014, must be 0x4D563449 "MV4I"), ENG_CAPS (0x1201C:
  NPORTS_W [7:0], NPORTS_S [15:8]), then for every counter i, `UTIL_SEL=2i`, read
  `UTIL_DATA` (low 32 bits, latches the high 16), `UTIL_SEL=2i+1`, read `UTIL_DATA`
  (`fk33_regs.h:118-131,169-182`). Counter `NPORTS_W+NPORTS_S` (27 on this build: 24 + 3,
  the manifests' `nports_w` 24, `axi_read_masters` 27) is the A-job cycle count.
  The counters accumulate over all 23 GOs since the `util-clear`.
- Gate: `^JCUTIL_DONE die A` and `die B`; per die one `^JCUTIL die X nports_w 24 nports_s 3
  jobcyc N` with N > 0; `^JCUTIL_SUMMARY` gives min/mean/max of beats/jobcyc over the 24
  weight ports. Spec section 7's target is A at 95% or more of `24 x 32 B x f` during A jobs,
  i.e. every weight port's ratio >= 0.95; report the shortfall otherwise.
- Token time, three numbers, all from these files:
  - on-card time of the last GO on each die: `cycles` on the `^last job` line
    (SEAM_CYCLES, GO to done, `fk33_seam.h:257`) / 125e6 s. One token through the pipe is
    the sum of the two dies' values (the dies run in series per token).
  - A's share: `jobcyc` / 23 GOs / 125e6 s per die (job cycles are clk_core cycles: on
    this board hbm_aclk and clk_core are one net, `hw/jc/card/gen_jc_card.py:464` "ON THIS
    BOARD core_clk AND hbm_aclk ARE THE SAME NET").
  - host wall per position: the `timing` line's `run_chunk` seconds / GOs
    (`run_prompt.c:763`). This is dominated by the JTAG hop, not the card.
- Duration, ESTIMATE: 28 counters x 4 accesses x ~3 ms = ~0.4 s per die.
- Failure: `JCUTIL_FAIL ... engine ID` (0x12000 not decoded: the BD address map did not
  hold), `JCSEAM_ERROR ... 0xDEADDEAD` (the counter domain did not answer,
  `fk33_regs.h` FK33_ENG_UTIL_DEAD), `jobcyc 0` (no A job ran since the clear).
- Then write `docs/debugging/2026-10-xx_jc-27b-first-token.md` with these files' raw
  lines (Task 12 step 6).

## 6. Step 5 for reference: the 500-token context test

```bash
JC_SOCK=$SOCK JC_RUN0=$W/card0 JC_RUN1=$W/card1 JC_MAN0=$MAN0 JC_MAN1=$MAN1 \
  bash $REPO/hw/jc/host/jc_ctxtest.sh pair $W/ctxtest/n500 500 --dry-run     # prints, touches nothing
bash $REPO/hw/jc/host/jc_bc_lane.sh rezero --dry-run > $W/rezero_dry.txt  # the prep, printed only
JC_SOCK=$SOCK JC_RUN0=$W/card0 JC_RUN1=$W/card1 JC_MAN0=$MAN0 JC_MAN1=$MAN1 \
  bash $REPO/hw/jc/host/jc_ctxtest.sh pair $W/ctxtest/n500 500
grep -E '^CTXTEST_(PASS|FAIL)' $W/ctxtest/n500/ctxtest.log
```

- Before EVERY run the script re-zeroes the GDN state, as the FK33 flow does (section 0
  item 8): `JC_PREP` defaults to `bash $REPO/hw/jc/host/jc_bc_lane.sh rezero`, which stops
  the broker, runs `coe_load.py load` then `verify` of `$BCW/cardN/side_gdn.json` on die A
  (card 0) and die B (card 1), gating on `^JCLOAD_DONE ` and
  `^JCVERIFY_PASS [0-9]+ pieces, 0 bad`, and restarts the broker. A failed zero stops before
  the restart, and the run fails `CTXTEST_FAIL ...: JC_PREP failed`. It reads the
  `JC_BC/JC_BMC/JC_BCW/JC_BC_MAN0/JC_BC_MAN1` exported in section 1. The ssh forward
  survives the restart because it connects to the remote path per connection.
  `JC_NO_REZERO=1` turns it off (the log then says so); not for the gate run.
- Prep duration, ESTIMATE: 78.7 MB per die at ~2.6 MB/s = ~30 s load plus the range-CRC
  verify, for both dies, plus broker stop and start: about 1.5-2 min per run.
- `single` mode needs a whole-model image on one die, which neither 27B image is.
- Gate: `^CTXTEST_PASS` only. Duration, ESTIMATE: 4 runs x 500 positions x ~15 s = ~8 h,
  plus ~2 min of `JC_PREP` per run. Measure the per-position wall time in 4.1 first and
  restate this before starting it.

## 7. Gaps this runbook could not close

Closed 2026-10-09 (section 0): the `run_prompt --jc` flags (item 1); HBM writes stay with
`coe_load.py`, per the spec and the RTL (item 2); the broker's `--manifest` paths (item 4);
the GDN re-zero before every sequence (item 8). Still open:

1. Nothing in steps 3-6 has run against the board. The `--jc` path is tested only against
   the simulated seam behind a fake broker; its first real use with `jc_broker.py` and the
   USER3 core is 3.5, then 4.1.
2. Window 4 does not exist; the counters are at the engine map (section 0 item 3). The plan
   text for Task 1/Task 12 step 6 is stale on this point.
3. The BC-250's manifest paths are now named (`~/jc_models/...`, section 1), but their
   presence there is not verified from the workstation: P7.
4. Per-read broker latency is not measured. Every duration above that depends on it is an
   ESTIMATE from the unpipelined BMC shift time; 4.1's `timing` line is the first
   measurement.
5. Whether the GDN zero is NEEDED between sequences is still not determined (the RTL masks
   the recurrent read at `tk0` and zeroes invalid conv taps, section 0 item 8). It no longer
   blocks these steps: the JC zeroes before every sequence, as the FK33 did. One run with
   `JC_NO_REZERO=1` compared with the gated run would answer it; that is optional.
6. `fk33ctl.py seam`'s CAPS check is hardcoded to the 9B (expected MISMATCH lines).
