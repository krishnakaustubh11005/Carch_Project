# RTL changes require scoped authorization; tooling discovers tb/tb_*.v.
.DEFAULT_GOAL := all
.NOTPARALLEL:
PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
GTKWAVE ?= gtkwave
TIMEOUT ?= 30
WIDTHS ?=
K_MAX ?= 256
ACC_W ?=
ROWS ?= 7
ARRAY_MATRICES ?= golden/array_matrices.json
ACCELERATOR_MATRICES ?= golden/accelerator_matrices.json
STREAM_COUNT ?= 100
STREAM_SEED ?= 20261105
RUNNER = $(PYTHON) scripts/verify.py
OPTIONS = --iverilog "$(IVERILOG)" --vvp "$(VVP)" --timeout "$(TIMEOUT)" --widths "$(WIDTHS)" --rows "$(ROWS)" --k-max "$(K_MAX)" --array-matrices "$(ARRAY_MATRICES)" $(if $(ACC_W),--acc-w "$(ACC_W)")
ARRAY_RTL = rtl/half_adder.v rtl/full_adder.v rtl/booth_recoder.v \
	rtl/booth_pp_gen.v rtl/compressor_tree.v rtl/booth_mac_datapath.v \
	rtl/pe_booth_csa.v rtl/systolic_4_4_array.v

.PHONY: all test check lint golden golden-array summary wave help clean test-tooling visualize compile-array demo-array wave-array test-array wave-array-matmul sw bench
.PHONY: test-array-stream wave-array-stream test-array-sizes wave-array-sizes
.PHONY: test-array-controls wave-array-controls
.PHONY: test-accelerator wave-accelerator
.PHONY: test-mmio wave-mmio
.PHONY: test-processor wave-processor
all:
	@$(MAKE) --no-print-directory lint
	@$(MAKE) --no-print-directory test

test:
	@$(RUNNER) test $(OPTIONS)

# Strict acceptance: pending hardware makes this target fail.
check:
	@$(RUNNER) test $(OPTIONS) --strict

test-%:
	@$(RUNNER) test --module "$*" $(OPTIONS)

lint:
	@$(RUNNER) lint --verilator "$(VERILATOR)" --timeout "$(TIMEOUT)"

golden:
	@$(PYTHON) golden/model.py

golden-array:
	@$(PYTHON) golden/array_vectors.py --matrices "$(ARRAY_MATRICES)"

summary:
	@$(RUNNER) summary

wave:
	@$(RUNNER) wave --module "$(MOD)" --gtkwave "$(GTKWAVE)"

visualize:
	@YOSYS="$(YOSYS)" $(PYTHON) visualizer/server.py

.PHONY: visualize-setup
visualize-setup:
	npm ci --prefix visualizer --no-audit --no-fund
	$(PYTHON) -m venv visualizer/.venv
	visualizer/.venv/bin/pip install -r visualizer/requirements.txt

test-tooling:
	@$(PYTHON) -m unittest discover -s scripts/tests -v

# Syntax/elaboration only; directed functional checks are in test-array.
compile-array:
	@mkdir -p sim/build
	@$(IVERILOG) -g2001 -s systolic_4_4_array -o sim/build/systolic_4_4_array.vvp $(ARRAY_RTL)
	@echo 'Array compiled; syntax/elaboration only. Run make test-array for the directed test.'

# Two consecutive input steps for waveform inspection; not the full array suite.
demo-array:
	@mkdir -p sim/build sim/vcd
	@$(IVERILOG) -g2001 -s demo_systolic_4_4_array -o sim/build/array_demo.vvp tb/demo_systolic_4_4_array.v $(ARRAY_RTL)
	@$(VVP) sim/build/array_demo.vvp

wave-array: demo-array
	@$(GTKWAVE) sim/vcd/array_demo.vcd

# Two complete 4x4 multiplications; print each result as its PE publishes it.
test-array: golden-array
	@$(RUNNER) test --module systolic_4_4_array $(OPTIONS) --verbose

test-accelerator:
	@$(RUNNER) test --module accelerator_4x4 $(OPTIONS) --array-matrices "$(ACCELERATOR_MATRICES)" --verbose

wave-accelerator: test-accelerator
	@$(GTKWAVE) sim/vcd/accelerator_4x4.vcd

test-mmio:
	@$(RUNNER) test --module accelerator_mmio $(OPTIONS) --array-matrices "$(ACCELERATOR_MATRICES)" --verbose

wave-mmio: test-mmio
	@$(GTKWAVE) sim/vcd/accelerator_mmio.vcd

test-processor:
	@$(PYTHON) scripts/run_processor.py --matrices "$(ACCELERATOR_MATRICES)" --iverilog "$(IVERILOG)" --vvp "$(VVP)"

wave-processor:
	@$(PYTHON) scripts/run_processor.py --matrices "$(ACCELERATOR_MATRICES)" --iverilog "$(IVERILOG)" --vvp "$(VVP)" --vcd
	@$(GTKWAVE) sim/vcd/processor_accelerator.vcd

test-array-controls:
	@$(RUNNER) test --module systolic_4_4_array $(OPTIONS) --array-controls --verbose

wave-array-controls: test-array-controls
	@$(GTKWAVE) sim/vcd/systolic_4_4_array.vcd

# Generate a continuous stream and check every publication; full transcript in logs.
test-array-stream:
	@$(PYTHON) golden/array_stream.py --count "$(STREAM_COUNT)" --seed "$(STREAM_SEED)"
	@$(RUNNER) test --module systolic_4_4_array $(OPTIONS) --array-matrices sim/build/vectors/array_stream_matrices.json
	@cp sim/build/logs/systolic_4_4_array.log sim/build/logs/array_stream.log
	@cp sim/build/vectors/array_results.json sim/build/vectors/array_stream_results.json
	@cp sim/build/vectors/systolic_4_4_array.txt sim/build/vectors/array_stream.txt
	@cp sim/vcd/systolic_4_4_array.vcd sim/vcd/array_stream.vcd
	@tail -n 4 sim/build/logs/array_stream.log

wave-array-stream: test-array-stream
	@$(GTKWAVE) sim/vcd/array_stream.vcd

test-array-sizes:
	@$(PYTHON) golden/array_sizes.py --seed "$(STREAM_SEED)"
	@$(RUNNER) test --module systolic_4_4_array $(OPTIONS) --array-matrices sim/build/vectors/array_sizes_matrices.json
	@cp sim/build/logs/systolic_4_4_array.log sim/build/logs/array_sizes.log
	@cp sim/build/vectors/array_results.json sim/build/vectors/array_sizes_results.json
	@cp sim/build/vectors/systolic_4_4_array.txt sim/build/vectors/array_sizes.txt
	@cp sim/vcd/systolic_4_4_array.vcd sim/vcd/array_sizes.vcd
	@tail -n 4 sim/build/logs/array_sizes.log

wave-array-sizes: test-array-sizes
	@$(GTKWAVE) sim/vcd/array_sizes.vcd

wave-array-matmul: test-array
	@$(GTKWAVE) sim/vcd/systolic_4_4_array.vcd

clean:
	@$(RUNNER) clean

sw bench:
	@echo "$@: not implemented; this phase ends at PE verification."
	@exit 2

help:
	@echo 'make                     Lint, then test; pending modules are reported'
	@echo 'make test                Test available hardware and print a summary'
	@echo 'make check               Require every discovered module to pass'
	@echo 'make test-half_adder      Test one module and its dependencies'
	@echo 'make test-booth_recoder   Check 8 windows and all 256 signed INT8 values'
	@echo 'make test-booth_pp_gen    Verify biased Booth rows across operand widths'
	@echo 'make test-compressor_tree WIDTHS="24" ROWS=7'
	@echo 'make test-signed_multiplier  Exhaustive INT8 Booth/tree multiplier test'
	@echo 'make test-booth_mac_datapath  Verify arbitrary carry-save accumulator inputs'
	@echo 'make test-pe WIDTHS="4 8" K_MAX=256 ACC_W=24'
	@echo '  test-pe aliases test-pe_booth_csa (clocked Booth/CSA PE)'
	@echo 'make compile-array       Compile fixed 4x4 RTL only; full verification pending'
	@echo 'make demo-array          Simulate two consecutive input steps; write array_demo.vcd'
	@echo 'make wave-array          Run the demo and open its waveform in GTKWave'
	@echo 'make test-array          Run two back-to-back 4x4 matmuls; print 32 results'
	@echo 'make test-accelerator    Check controller, storage, busy behavior, and reset recovery'
	@echo 'make wave-accelerator    Run wrapper tests and open their waveform'
	@echo 'make test-mmio           Check MMIO protocol, register map, and matrix results'
	@echo 'make wave-mmio           Run MMIO tests and open their waveform'
	@echo 'make test-processor      Run CPU firmware against the MMIO accelerator'
	@echo 'make wave-processor      Run firmware and open the system waveform'
	@echo 'make test-array-controls Check stalls, bubbles, and reset/clear recovery'
	@echo 'make wave-array-controls Run control checks and open their waveform'
	@echo 'make test-array-stream   Check STREAM_COUNT=100 matmuls with STREAM_SEED=20261105'
	@echo 'make wave-array-stream   Check a stream and open GTKWave'
	@echo 'make test-array-sizes    Check mixed 4xK times Kx4 matrices (K=1 through 256)'
	@echo 'make wave-array-sizes    Run mixed-size tests and open GTKWave'
	@echo 'make golden-array        Calculate Python matrix products and export RTL vectors'
	@echo '  ARRAY_MATRICES=path.json selects two custom signed INT8 matrix pairs'
	@echo 'make wave-array-matmul   Run the two-matmul test and open GTKWave'
	@echo 'make lint / golden       Lint available RTL / generate reference vectors'
	@echo 'make wave MOD=half_adder  Open a generated VCD (GTKWave required)'
	@echo 'make summary             Display the most recent test report'
	@echo 'make visualize           Open the local RTL interface and hierarchy viewer'
	@echo 'make visualize-setup     Install local ELK layout and portable Yosys dependencies'
	@echo 'make test-tooling         Verify the runner and Python golden model'
	@echo 'make clean               Remove generated build, waveform, and vector files'
	@echo 'Overrides: PYTHON IVERILOG VVP VERILATOR GTKWAVE TIMEOUT WIDTHS ROWS K_MAX ACC_W ARRAY_MATRICES'
