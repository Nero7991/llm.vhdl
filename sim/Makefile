GHDL     ?= ghdl
STD      ?= --std=08
# util_pkg first (needed by everything); wq_l0_rom_pkg next (needed by
# matvec_engine, which sorts before it alphabetically); rope_rom_pkg,
# lmhead_rom_pkg and embed_rom_pkg must precede their consumers (rope.vhd /
# lm_head.vhd / embed.vhd, which all sort BEFORE the pkg name alphabetically);
# then the rest.
# rom_init_pkg (file-init BRAM loader) must precede matmul_rt/embed/lm_head;
# rms_weights_pkg (small split-out RMS constants) must precede engine_shared.
PINNED   := ../rtl/util_pkg.vhd ../rtl/rom_init_pkg.vhd ../rtl/rms_weights_pkg.vhd ../rtl/weights_pkg.vhd ../rtl/wq_l0_rom_pkg.vhd ../rtl/rope_rom_pkg.vhd ../rtl/lmhead_rom_pkg.vhd ../rtl/embed_rom_pkg.vhd
# layer_fsm.vhd and layer_ar.vhd instantiate rmsnorm/matmul/rope/attention/
# swiglu by direct entity binding, so they must be analyzed AFTER them (they
# sort before matmul/rmsnorm/rope/swiglu alphabetically) -> pin them LAST.
# engine.vhd instantiates embed/layer_ar/rmsnorm/lm_head/sampler, so it must
# come AFTER layer_ar -> pin it after layer_ar.
# engine_shared.vhd instantiates embed/rmsnorm/matmul_rt/rope/attention_ml/
# swiglu/lm_head/sampler (all leaf units in the wildcard middle), so it must be
# analyzed AFTER them -> pin it LAST.
LAST     := ../rtl/layer_fsm.vhd ../rtl/layer_ar.vhd ../rtl/engine.vhd ../rtl/engine_shared.vhd
RTL      := $(PINNED) $(filter-out $(PINNED) $(LAST),$(wildcard ../rtl/*.vhd)) $(LAST)
# sim-local packages (golden_pkg etc.) analyzed before each TB
SIM_PKGS := golden_pkg.vhd
TB       ?= tb_smoke
WORK     := work-obj08.cf
# The file-init ROM loader (rom_init_pkg.init_rom_hex) builds a large
# integer_vector (up to 226560 elems, ~900 KB) as a function-local temporary;
# raise ghdl-mcode's stack-object cap so elaboration does not reject it.
RUNFLAGS ?= --max-stack-alloc=0

analyze:
	$(GHDL) -a $(STD) $(RTL) $(SIM_PKGS) ../tb/$(TB).vhd
run: analyze
	$(GHDL) --elab-run $(STD) $(TB) $(RUNFLAGS)
all:
	@for t in $(wildcard ../tb/tb_*.vhd); do \
	  n=$$(basename $$t .vhd); echo "== $$n =="; \
	  $(GHDL) -a $(STD) $(RTL) $(SIM_PKGS) $$t && $(GHDL) --elab-run $(STD) $$n $(RUNFLAGS) || exit 1; \
	done
clean:
	rm -f $(WORK) *.o *.ghw *.vcd
