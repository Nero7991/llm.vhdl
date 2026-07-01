GHDL   ?= ghdl
STD    ?= --std=08
RTL    := $(wildcard ../rtl/*.vhd)
TB     ?= tb_smoke
WORK   := work-obj08.cf

analyze:
	$(GHDL) -a $(STD) $(RTL) ../tb/$(TB).vhd
run: analyze
	$(GHDL) --elab-run $(STD) $(TB)
all:
	@for t in $(wildcard ../tb/tb_*.vhd); do \
	  n=$$(basename $$t .vhd); echo "== $$n =="; \
	  $(GHDL) -a $(STD) $(RTL) $$t && $(GHDL) --elab-run $(STD) $$n || exit 1; \
	done
clean:
	rm -f $(WORK) *.o *.ghw *.vcd
