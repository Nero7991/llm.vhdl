GHDL     ?= ghdl
STD      ?= --std=08
# util_pkg first (needed by everything); wq_l0_rom_pkg next (needed by
# matvec_engine, which sorts before it alphabetically); then the rest.
RTL      := ../rtl/util_pkg.vhd ../rtl/wq_l0_rom_pkg.vhd $(filter-out ../rtl/util_pkg.vhd ../rtl/wq_l0_rom_pkg.vhd,$(wildcard ../rtl/*.vhd))
# sim-local packages (golden_pkg etc.) analyzed before each TB
SIM_PKGS := golden_pkg.vhd
TB       ?= tb_smoke
WORK     := work-obj08.cf

analyze:
	$(GHDL) -a $(STD) $(RTL) $(SIM_PKGS) ../tb/$(TB).vhd
run: analyze
	$(GHDL) --elab-run $(STD) $(TB)
all:
	@for t in $(wildcard ../tb/tb_*.vhd); do \
	  n=$$(basename $$t .vhd); echo "== $$n =="; \
	  $(GHDL) -a $(STD) $(RTL) $(SIM_PKGS) $$t && $(GHDL) --elab-run $(STD) $$n || exit 1; \
	done
clean:
	rm -f $(WORK) *.o *.ghw *.vcd
