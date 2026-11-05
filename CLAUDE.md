# CArch Project: Systolic Array Matmul Accelerator

## Goal and Current Phase
Parameterized N x N output-stationary systolic array, with signed operands defaulting to INT8, verified against an exact Python golden model. FPGA implementation, sequential-software benchmarking, and RISC-V integration follow later. PicoRV32 remains a candidate, not a settled integration choice.

Current work adds a fixed 4x4 array around the verified PE, with functional array verification deferred until contributor review. Read `docs/STATUS.md` first; use `docs/decisions.md` for decisions and `docs/IMPLEMENTATION.md` for interfaces and coding instructions.

## Ownership and Collaboration
- The assistant may write hardware RTL only for modules and scope explicitly authorized by the contributor. The current Booth workflow requires stopping after every stage for review; the clocked Booth/CSA PE is now authorized and implemented with the agreed interface. Stop for review before implementing the baseline or variant wrapper. Preserve existing half/full-adder RTL and reuse it by instantiation later.
- The assistant provides explanations, coding instructions, reviews/debugging, documentation, testbenches, golden models, and Makefile maintenance.
- The completed arithmetic stages now feed the clocked Booth/CSA PE, implemented before the baseline at the contributor's request. Stop for review; a behavioral baseline and wrapper/cross-check remain subsequent authorized stages. The contributor has now authorized the fixed 4x4 array RTL; stop for review before its functional verification.
- At unresolved design forks, present 2-3 options with trade-offs and a recommendation, then wait for the contributor's choice. Do not reopen already accepted choices unnecessarily.
- Suggest improvements explicitly as suggestions; disagree when there is a reason. Keep responses short and concrete.

## Accepted PE Design
- Output-stationary, one clock, shared array enable; operand movement is A rightward and B downward.
- Independent A/B valid bits; forward both streams on enabled cycles and MAC current inputs only when both are valid.
- `DATA_W=8`, signed two's-complement, widths >=2. `K_MAX=256` is independent of array size N.
- Default `ACC_W=2*DATA_W+ceil(log2(K_MAX))`, giving 24 bits; ceiling logarithm is zero for K_MAX=1. Reject smaller configurations in verification.
- The latest requested implementation direction supersedes Baugh-Wooley: compare a behavioral baseline with a radix-4 Booth/carry-save MAC. Reuse existing FA/HA cells structurally; no operand multiplication in the Booth datapath; multiplication in constant sizing/index expressions is allowed. Its S/C accumulator must not have carry-propagate addition in its feedback loop. Baseline multiplication is an explicit exception to custom arithmetic.
- Full product arithmetic is 2*DATA_W signed, correctly extended into ACC_W. Fixed-width wrap arithmetic, no saturation; supported operations do not exceed K_MAX accepted MACs. A ripple-carry accumulator feedback path is superseded for the Booth/CSA variant.
- Synchronous active-high reset/clear override all work. Drain independently publishes the old S+C; en independently forwards streams and accepts a MAC when both valid bits are high. On drain, the MAC uses zero accumulator contributions, starting the next tile with the current product. Without an accepted MAC, drain zeros both S/C registers. One forwarding hop per enabled cycle; no extra MAC input pipeline.
- The accepted clocked PE exposes signed result plus result_valid on drain; the continuous acc_out interface is superseded. Drain works with en=0 and clears accumulator state. Consecutive drain edges can publish consecutive tiles while accepting their successors; without accepted MACs, subsequent drains publish zero. Result holds between drains; result_valid clears on the next non-drain clock even while stalled. The contributor selected clocked Booth/CSA before the baseline; the baseline and MUL_TYPE wrapper remain deferred.

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

## Fixed 4x4 Array Review Stage
- The contributor requested an unparameterized array, then approved generate blocks and shift registers to reduce repetition. `systolic_4_4_array` fixes N=4, signed operand width 8, K_MAX=256, and accumulator width 24. Use Verilog-2001 generate loops for skew/mesh, packed shift registers, and internal wire arrays; reuse PE modules unchanged. No helper functions or SystemVerilog array ports are needed.
- Packed A/B input buses have four byte lanes, lane 0 in the lowest byte, plus per-lane valid bits. The source supplies matching k positions; internal skew delays lanes by 0/1/2/3 enabled cycles.
- One drain_in supplies four row buses through shared delay stages. drain_rows[row][3-column] drives each PE; bit 3 is column 0. The pulse moves right and each row starts one enabled cycle later, preserving row+column delay 0-6. en pauses every pipeline and gates local drain. rst/clear zero all skew, boundary, and PE state synchronously.
- Expose 384 result bits and 16 valid bits in row-major order, PE(0,0) in the lowest slice. No result collector or backpressure. Result valid pulses are observed every clock, independently of en.
- `make compile-array` checks syntax/elaboration only. The contributor authorized a small two-step waveform demo: `make demo-array` simulates it and `make wave-array` opens GTKWave. Keep tb/demo_systolic_4_4_array.v outside full-suite discovery; it checks one directed K=2 example. Comprehensive array verification remains pending. Preserve the existing PE verification suite and AGENTS.md.

## Directed Back-to-Back Array Test
- The contributor authorized tb/tb_systolic_4_4_array.v for two complete 4x4 multiplications. Use basic loops for stimulus. The two signed matrix pairs now live in golden/array_matrices.json; Python model.matrix_multiply is the sole expected-product calculation. Export row-major A/B/C hex records and load them into signed TB memories; do not duplicate golden arithmetic in Verilog. Print every PE publication with multiplication identity and check all 32 results, per-PE counts, and arrival cycles.
- make test-array prints results directly; make wave-array-matmul opens its trace. scripts/verify.py now discovers this test with the existing PE dependency closure. Full random/stall/reset/clear array coverage remains future work. The older two-step waveform demo is retained.

## Python Array Golden Flow
- make golden-array regenerates the two input/expected matrices and prints C. make test-array and wave-array-matmul depend on it. ARRAY_MATRICES selects a custom JSON source with one or more 4xK/Kx4 pairs, with K from 1 to 256; scripts/verify.py regenerates its own build-local golden vectors for suite runs.
- Testbench parsing rejects missing/empty/truncated/extra/unknown records, and signed 24-bit expected values must be sign-extended when compared. The variable-K format is a decimal K header, 4*K hexadecimal A/B byte-pair records, then 16 hexadecimal signed 24-bit C values per case. Regenerate legacy vectors. The runner derives the testbench MATRIX_COUNT from the case count. Preserve fixed hardware dimensions and continuous tile timing.

## Continuous Array Stream Verification
- make test-array-stream uses STREAM_COUNT=100 and STREAM_SEED=20261105 by default. Generate eight directed corner pairs then full-range random INT8 pairs, calculate Python golden outputs, and run the same simple Verilog array testbench with testbench-only MATRIX_COUNT sizing. Do not parameterize or otherwise change array RTL for stream length.
- Every PE publication is logged and checked for value, matrix identity, count, and exact uninterrupted arrival cycle. Archive stream inputs/results/vectors/log and VCD under sim/build and sim/vcd so a later default test does not replace the stream evidence.

## Mixed Input Shapes with 4x4 Outputs
- make test-array-sizes checks 15 back-to-back 4xK times Kx4 cases, with K=1/2/3/4/5/7/8/16/31/64/128/256 and repeated adjacent K=1 cases. make wave-array-sizes opens its archived trace.
- Testbench inner_size records K per case; pe00_matrix selects the counter threshold and advances on drain. Input memories allow at most 4*256 bytes per operand. Expected arrival cycles use cumulative K plus row+column, not fixed multiples of four. No array/PE RTL changes.
