# CArch Project: Systolic Array Matmul Accelerator

## Goal and Current Phase
Parameterized N x N output-stationary systolic array, with signed operands defaulting to INT8, verified against an exact Python golden model. FPGA implementation, sequential-software benchmarking, and RISC-V integration follow later. PicoRV32 remains a candidate, not a settled integration choice.

Current phase ends at a verified PE. Read `docs/STATUS.md` first; use `docs/decisions.md` for decisions and `docs/IMPLEMENTATION.md` for interfaces and coding instructions.

## Ownership and Collaboration
- The assistant may write hardware RTL only for modules and scope explicitly authorized by the contributor. The current Booth workflow requires stopping after every stage for review; the clocked Booth/CSA PE is now authorized and implemented with the agreed interface. Stop for review before implementing the baseline or variant wrapper. Preserve existing half/full-adder RTL and reuse it by instantiation later.
- The assistant provides explanations, coding instructions, reviews/debugging, documentation, testbenches, golden models, and Makefile maintenance.
- The completed arithmetic stages now feed the clocked Booth/CSA PE, implemented before the baseline at the contributor's request. Stop for review; a behavioral baseline and wrapper/cross-check remain subsequent authorized stages. Discuss array integration after PE verification.
- At unresolved design forks, present 2-3 options with trade-offs and a recommendation, then wait for the contributor's choice. Do not reopen already accepted choices unnecessarily.
- Suggest improvements explicitly as suggestions; disagree when there is a reason. Keep responses short and concrete.

## Accepted PE Design
- Output-stationary, one clock, shared array enable; operand movement is A rightward and B downward.
- Independent A/B valid bits; forward both streams on enabled cycles and MAC current inputs only when both are valid.
- `DATA_W=8`, signed two's-complement, widths >=2. `K_MAX=256` is independent of array size N.
- Default `ACC_W=2*DATA_W+ceil(log2(K_MAX))`, giving 24 bits; ceiling logarithm is zero for K_MAX=1. Reject smaller configurations in verification.
- The latest requested implementation direction supersedes Baugh-Wooley: compare a behavioral baseline with a radix-4 Booth/carry-save MAC. Reuse existing FA/HA cells structurally; no operand multiplication in the Booth datapath; multiplication in constant sizing/index expressions is allowed. Its S/C accumulator must not have carry-propagate addition in its feedback loop. Baseline multiplication is an explicit exception to custom arithmetic.
- Full product arithmetic is 2*DATA_W signed, correctly extended into ACC_W. Fixed-width wrap arithmetic, no saturation; supported operations do not exceed K_MAX accepted MACs. A ripple-carry accumulator feedback path is superseded for the Booth/CSA variant.
- Synchronous active-high priority `rst > clear > drain > en > hold`. Reset/clear zero all PE state even while stalled. Drain freezes forwarding and S/C, suppresses MAC, and publishes result after its sampled edge. One forwarding hop per enabled cycle; no extra MAC input pipeline.
- The accepted clocked PE exposes signed result plus result_valid on drain; the continuous acc_out interface is superseded. Drain works with en=0, holds accumulator state, and may be repeated. Result holds between drains; result_valid clears on the next non-drain clock even while stalled. The contributor selected clocked Booth/CSA before the baseline; the baseline and MUL_TYPE wrapper remain deferred.

## Coding and Verification
- Verilog-2001, one module per matching filename, four-space indentation, explicit signed declarations, parameters rather than magic widths. Single-bit control naming follows the implementation guide.
- Prefer direct parameter/localparam expressions, descriptive intermediate buses, and generate/assign blocks in the compressor and MAC. Do not reintroduce custom constant helper functions there. Arithmetic hardware must remain explicit and inspectable. FPGA resource mapping and timing must be measured; DSP inference is no longer a requirement for this phase.
- Every module gets a self-checking `tb/tb_<module>.v` and Makefile access. Simulations print a final `TEST PASSED` or `TEST FAILED`; the runner rejects absent success markers, errors, and timeouts.
- Exhaustively test one-bit adders and small multiplier widths; test odd widths, signed extremes, zero, deterministic random cases, reset, clear, stalls, and bubbles.
- Golden arithmetic must exactly match operand interpretation, accumulator width, and wrap behavior. Later array/top tests use generated golden outputs rather than manually entered expected matrices.
- Never claim a check passed without running it. Distinguish PENDING hardware, SKIP lint, and PASS tests.

## Build Control
`make` runs lint then discovered tests. `make test-<module>` runs an individual module and dependency closure. `make check` requires all discovered modules to pass. `make test-tooling` validates the runner/reference model. Other commands: `make golden`, `make summary`, `make wave MOD=<module>`, `make help`, `make clean`.

Missing RTL is PENDING; explicit module requests and strict completion checks fail on pending hardware. Verilator absence is SKIP. Build artifacts belong in `sim/build/`, waveforms in `sim/vcd/`. Update tooling with each new module. Firmware/benchmark targets remain unimplemented and must not imply successful builds.

## Accuracy and File Changes
- Never invent tool flags, IP names, functions, or file contents; inspect files/help first.
- State and fix failures plainly. Preserve the contributor's unrelated edits.
- Do not rename or delete source files unasked. List intended files for changes beyond the current module.
- Record architectural decisions with date, rationale, and rejected alternatives; keep status current.
- Preserve `AGENTS.md` as requested. Repository directories are `rtl/`, `tb/`, `golden/`, `sw/`, `bench/`, `sim/`, `fpga/`, `docs/`, `data/`, `scripts/`, and `constraints/`.

## Fixed-Point Interpretation
The PE also accepts signed fixed-point bit patterns: F fractional bits per operand imply 2F fractional bits in the accumulated result. Preserve raw integer arithmetic; no new fractional-bit parameter, rounding, saturation, or scaling hardware has been requested.
