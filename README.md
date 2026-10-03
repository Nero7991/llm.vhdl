# llm.vhdl

Full-fabric VHDL LLM inference engine. Runs Qwen3.5-class transformer
inference (9B on a single card, 27B targeted across two) entirely in FPGA
fabric: INT4 streaming matvec, Gated DeltaNet, gated attention, and a
transformer sequencer, with the weights resident in on-card HBM.

Target card: SQRL FK33 (`xcvu33p-fsvh2104-2L-e`, 8 GiB HBM, PCIe Gen3 x4).

## Deploy to an FK33, end to end

This runs the validated silicon path. The host tooling opens `/dev/xdma*`;
run it as a human on the box, never unattended. See
`docs/2026-08-27_fk33-pcie-bringup-procedure.md` for the long form.

Prerequisites: an FK33 in a PCIe slot, Vivado 2023.2, a Linux host, and the
Qwen3.5-9B weight image with its `MANIFEST.json` (layout in
`docs/2026-08-27_hbm-residency-map.md`).

```bash
# 1. Build the endpoint bitstream (~1-1.5 h; or reuse hw/fk33/bit/*.bit).
#    FK33_CARD=1 adds the B/C/D subsystems; engine-only omits it.
FK33_CARD=1 hw/fk33/pcieep_build.sh

# 2. Host-side XDMA driver (once), then grant group access (once per boot).
hw/fk33/host/build_xdma_driver.sh          # compiles, installs nothing
sudo hw/fk33/host/setup-fk33-access.sh     # loads xdma, 0660 group access

# 3. Program the card over JTAG (bus is taken down and rescanned around it).
hw/fk33/host/fk33_reload.sh hw/fk33/bit/fk33_pcieep_eng.bit

# 4. Place the 9B weight image into HBM and verify it landed.
hw/fk33/host/fk33_load_weights.py load MANIFEST.json --verify

# 5. Sanity check: a short two-card context test (gate on CTXTEST_PASS).
hw/fk33/host/fk33_ctxtest.sh pair /mnt/storage/fk33_builds/ctxtest 256

# 6. Serve the web UI and chat. Build the tokenizer/template shim, then run
#    the server (two cards by default; --mode single for one).
make -C server libqwen35chat.so
python3 server/llmvhdl_server.py           # --mode single for one card
```

Then open `http://127.0.0.1:8000/` for the chat UI (a copy of the llama.cpp
web UI). It is greedy-only, one request at a time, no prompt cache; the server
docstring in `server/llmvhdl_server.py` explains why. Current measured decode
is about 2.5 tokens/s on the two-card pipeline.

## Status and ongoing work

`docs/WORKLOG.md` is the live board; `docs/` holds the dated design and
debugging notes. In flight:

- **9B on silicon** -- running across two FK33s as a pipeline split (card 0
  holds the early blocks, card 1 the rest plus the LM head).
  See `docs/PLAN_TO_FIRST_INFERENCE.md` and the two-card pipeline spec.
- **27B across two dies** -- fits a VU35P at about 46% LUT; composed timing
  and the no-PCIe host path are the open items.
  See `docs/2026-09-24_jungle-cat-performance-estimate.md`.
- **Jungle Cat carrier (2x VU35P) and the inter-card link** -- Aurora over
  spare GTY lanes, plus the tensor-parallel collective (subsystem E), are in
  design. See `docs/boards/jungle-cat/` and `docs/fpga-hardware-recon.md`.
- **Per-block fmax ratings** -- every shipping block clears 200 MHz on the
  VU35P -2 deployment grade; flow under `hw/targets/`.

## License

MIT (see [LICENSE](LICENSE)). Third-party components and their licenses are
listed in [NOTICE](NOTICE); the web UI in `ui/` is derived from the llama.cpp
web UI (MIT) and keeps its upstream notice in `ui/LICENSE.llama.cpp`.
