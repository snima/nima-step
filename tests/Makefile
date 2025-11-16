.PHONY: cocotb clean results

VERILOG_SOURCES := $(PWD)/ca_coprocessor.v
MODULE := test_ca_coprocessor
TOPLEVEL := ca_coprocessor
SIM ?= icarus
RESULTS_DIR ?= $(PWD)/results

cocotb: clean
	@echo "Running integrated performance tests..."
	@mkdir -p $(RESULTS_DIR)
	RESULTS_DIR=$(RESULTS_DIR) \
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL=$(TOPLEVEL) \
		MODULE=$(MODULE) \
		VERILOG_SOURCES=$(VERILOG_SOURCES) \
		COMPILE_ARGS="-g2012"

clean:
	rm -rf sim.vvp *.vcd *.fst __pycache__ results.xml sim_build
	rm -rf $(RESULTS_DIR)

results: cocotb
	@echo ""
	@echo "=== PERFORMANCE SUMMARY ==="
	@cat $(RESULTS_DIR)/summary.txt 2>/dev/null || echo "No results generated yet"
