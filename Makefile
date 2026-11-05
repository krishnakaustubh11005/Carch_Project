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
RUNNER = $(PYTHON) scripts/verify.py
OPTIONS = --iverilog "$(IVERILOG)" --vvp "$(VVP)" --timeout "$(TIMEOUT)" --widths "$(WIDTHS)" --rows "$(ROWS)" --k-max "$(K_MAX)" $(if $(ACC_W),--acc-w "$(ACC_W)")

<<<<<<< HEAD
.PHONY: all test check lint golden summary wave help clean test-tooling sw bench test-cpu test-golden-c
=======
.PHONY: all test check lint golden summary wave help clean test-tooling sw bench
>>>>>>> main
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

<<<<<<< HEAD
test-cpu:
	@$(PYTHON) golden/run_cpu.py

test-golden-c:
	@$(PYTHON) golden/compare_models.py

=======
>>>>>>> main
summary:
	@$(RUNNER) summary

wave:
	@$(RUNNER) wave --module "$(MOD)" --gtkwave "$(GTKWAVE)"

test-tooling:
	@$(PYTHON) -m unittest discover -s scripts/tests -v

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
	@echo 'make lint / golden       Lint available RTL / generate reference vectors'
	@echo 'make wave MOD=half_adder  Open a generated VCD (GTKWave required)'
	@echo 'make summary             Display the most recent test report'
	@echo 'make test-tooling         Verify the runner and Python golden model'
<<<<<<< HEAD
	@echo 'make test-cpu             Run C matrix multiplication on PicoRV32 (no accelerator)'
	@echo 'make test-golden-c        Compare C and Python matrix multiplication on the host'
=======
>>>>>>> main
	@echo 'make clean               Remove generated build, waveform, and vector files'
	@echo 'Overrides: PYTHON IVERILOG VVP VERILATOR GTKWAVE TIMEOUT WIDTHS ROWS K_MAX ACC_W'
