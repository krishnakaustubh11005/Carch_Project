# CArch Project: Systolic Array Matmul Accelerator

## Goal
Parameterized N x N systolic array INT8 matrix-multiply accelerator in Verilog, verified against a Python golden model, benchmarked against sequential software, and driven by an open-source RISC-V core (PicoRV32 is the current favorite). The CPU gives the accelerator matrix addresses, then the accelerator takes over.

## Status: design is OPEN
- Dataflow is undecided. Output-stationary is the default from the README. Weight-stationary is a possible stretch.
- Building bottom-up: PE -> skew -> array -> buffers/controller -> top -> CPU integration -> benchmark -> FPGA.
- Decisions get made on the fly. Log each one in `docs/decisions.md` as: date, decision, why, alternatives rejected.
- Keep `docs/STATUS.md` current: done, in progress, next, open questions. Read it first each session.

## How to work with me
1. At every design fork (dataflow, bit widths, interface, bus protocol), stop and give 2-3 options with trade-offs and a recommendation. Then wait for my choice. Don't silently pick.
2. Suggest improvements proactively, but flag them as suggestions. Disagree with me when you have a reason.
3. Work in small steps: one module, one testbench, a passing `make` target, then the next. Don't write several layers at once.
4. Keep answers short and casual. Code and diffs over explanation.

## Anti-hallucination rules
- Never invent tool flags, IP names, library functions, or file contents. If unsure, run `--help`, read the file, or say "I don't know".
- Never claim something works without running it. Quote the real command and its output.
- If a change breaks something, say so plainly and fix it. Don't hide it.
- Don't rename or delete files unasked. List what you plan to touch first for anything beyond the current module.

## Key design parameters (change only via decisions.md)
- `N` (array size), `DATA_W = 8` signed, `ACC_W` (decide explicitly: 16 wraps for large K, 16 + log2(K) is safe).
- The golden model must match RTL arithmetic exactly (signed, same accumulator width, same wrap behavior).
- Single clock to start. Multi-clock and async FIFOs are a stretch.

## RTL conventions
- Verilog-2001 style, one module per file in `rtl/`, `parameter`s not magic numbers, synchronous active-high reset unless told otherwise.
- Signed math declared explicitly (`signed` regs/wires). Watch width extension in multiplies.
- Names: `clk`, `rst`, `*_valid`, `*_ready`, `*_en`, `*_n` for active-low. Files named after the module.
- Structure must infer cleanly in Vivado: DSP for MAC, BRAM for buffers.

## Verification rules
- Every module gets a self-checking testbench in `tb/` that prints exactly `TEST PASSED` or `TEST FAILED` and exits.
- Corner cases always: all -128, all 127, zeros, identity, random seeds (fixed and logged).
- Array and top-level tests compare against `golden/` output files, never hand-typed numbers.
- Check latency against theory when known (e.g. N x N array, inner dim K: about K + 2N - 2 cycles).

## Control system (single-click): `Makefile` at the root
Build this first, before any RTL. Targets:
- `make` or `make all`: lint, then all tests, then summary. This is the one click.
- `make test-<module>` (e.g. `test-pe`, `test-array`, `test-top`): compile and run one testbench.
- `make test`: run every `test-*` and print a PASS/FAIL table.
- `make golden`: regenerate vectors and expected outputs with Python.
- `make wave MOD=<module>`: open the VCD in GTKWave.
- `make sw`: build RISC-V firmware. `make bench`: run the benchmarks, write `bench/results.csv`.
- `make clean`.
Rules for the Makefile: use `iverilog`/`vvp` for sim and `Verilator` for lint, auto-discover `tb/tb_*.v`, fail loudly (nonzero exit) on any FAIL, print a one-line summary per test, and keep build outputs in `sim/build/`.

## Repo layout
`rtl/ tb/ golden/ sw/ bench/ sim/ fpga/ docs/ data/ scripts/ constraints/` (rename the typo folders `systolic-array-sccelerator`, `contraints`, and `architechture.md` only with my OK).

## First tasks, in order
1. Scaffold the Makefile, `docs/STATUS.md`, and `docs/decisions.md`. Show me the tool versions you find installed.
2. `golden/` model and vector generator.
3. `rtl/pe.v` plus `tb/tb_pe.v`. Propose the PE interface and accumulator reset or tag-bit approach, with options, before coding.
