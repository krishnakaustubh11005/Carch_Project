#Computer Architechture Project

##Problem Statement
A parameterized n*n systolic array accelerator implemnted in verilog on FPGA performing int8 matrix multiplication using an output stationary data flow verified against software golden model and benchmarked for speed up over a sequential software implementation.

## Arithmetic modules and staged PE work

| Module | Ports / parameters | Registered latency |
|---|---|---|
| `half_adder` | `a,b` -> `sum,carry`; one-bit ports | 0 cycles (combinational) |
| `full_adder` | `a,b,cin` -> `sum,cout`; instantiates two half adders | 0 cycles (combinational) |
| `booth_recoder` | `y[2:0]` -> `sign,one,two`; one radix-4 digit | 0 cycles (combinational) |
| `booth_pp_gen` | DATA_W=8; signed `x` and `sign,one,two` -> unsigned DATA_W+2-bit `pp`, separate `neg` | 0 cycles (combinational) |
| `compressor_tree` | WIDTH=24, ROWS=7; packed `rows` -> aligned `sum,carry`; reuses FA/HA | 0 cycles (combinational) |
| `booth_mac_datapath` | DATA_W=8, ACC_W=DATA_W+DATA_W+8; `a,b,acc_s,acc_c` -> `sum,carry` | 0 cycles (combinational) |
| `signed_multiplier` | DATA_W=8; `a,b` -> full signed `product`; resolves only at output | 0 cycles (combinational) |
| `pe_booth_csa` | DATA_W=8, K_MAX=256, derived ACC_W=24; clocked valid streams, clear, drain, result | One forwarding hop; result after sampled drain edge |
| `systolic_4_4_array` | Fixed 4x4, INT8, K_MAX=256, ACC_W=24; packed inputs/results | Lane skew 0-3; drain diagonal offsets 0-6 enabled cycles; functional verification pending |

Run `make test-booth_recoder` for exhaustive window and signed INT8 reconstruction checks, or `make` for the available suite. The recoder is independent of DATA_W; both zero windows use sign=0.

## RTL Visualizer

Install dependencies once, then start the local viewer:

```sh
make visualize-setup  # Node/npm, Python 3, and Python venv support required
make visualize
```

Open [http://127.0.0.1:8000](http://127.0.0.1:8000). The first review milestone opens `full_adder`, showing its two half adders, the OR logic, and actual elaborated net connections—not guessed signal-name matches.

- Scroll to zoom around the cursor; drag the background to pan; use **Fit** to reset.
- Click a wire to highlight its branches and inspect aliases, drivers, and consumers.
- Click a block to inspect its ports/source. Double-click a module to enter its internals; use breadcrumbs to return with the previous viewport restored.
- Select another top in the sidebar or use **Rebuild design** after RTL changes. Layout of large modules is still experimental.

The viewer uses hierarchy-preserving Yosys elaboration (`hierarchy`, `proc -noopt`, JSON export) and locally installed ELK.js for orthogonal routing. Native `yosys` or `yowasp-yosys` on PATH takes precedence over the local portable tool. Override explicitly with `make visualize YOSYS=/path/to/yosys`.

Build scripts, logs, netlists, and normalized graphs are saved under `sim/build/visualizer/`. Missing tools and elaboration failures are shown explicitly; no guessed schematic is substituted.

**Current limits:** bus bits are drawn separately; inline expansion, bundled bus routing, parameter-override controls, and dedicated gate/register symbols remain planned. The first-release layout limit is 500 blocks / 5,000 bit-connections per opened module. This is elaborated RTL connectivity—not FPGA placement, timing analysis, or live simulation.

See [visualizer development notes](visualizer/README.md) for testing and scope.

Retained PE defaults: DATA_W=8, K_MAX=256, ACC_W=2*DATA_W+ceil(log2(K_MAX))=24. The clocked Booth/carry-save PE is implemented. The behavioral baseline and MUL_TYPE comparison wrapper remain deferred; no synthesis comparison is claimed. See [the implementation guide](docs/IMPLEMENTATION.md) for the six review stages. The fixed 4x4 array is now written for RTL review; functional array verification follows that review.

Run `make test-booth_pp_gen` for widths 2/3/4/8/16. Its row contract is `unsigned(pp)+neg = Booth_digit*x + 2^(DATA_W+1)`. The future tree must cancel the combined shifted biases: for INT8 and ACC_W=24 the constant is `0xFF5600`. Rows are zero-extended into that tree, not sign-extended. See the guide for the derivation and corner cases.

Run `make test-signed_multiplier` for exhaustive INT8 multiplication (65,536 pairs), `make test-compressor_tree` for structural sum-preservation checks, and `make test-booth_mac_datapath` for nonzero carry-save accumulator inputs. The INT8 tree reduces seven rows through 7->5->4->3->2, retaining two vectors with no carry-propagate adder in the MAC feedback path. The clocked Booth/CSA PE now instantiates this core; baseline/wrapper comparison remains future work.

## Clocked PE

Run `make test-pe` (alias of `make test-pe_booth_csa`) or `make wave MOD=pe`. Synchronous reset/clear override all work. Otherwise, en forwards independent A/B streams and accepts a current-input MAC when both valid bits are high, including on drain. Drain independently publishes the old S+C with result_valid after its rising edge. A MAC accepted on that edge starts from zero and belongs to the next tile; without an accepted MAC, drain zeros both S/C registers. Drain also works with en=0. Result_valid deasserts on the next non-drain clock; result holds until reset, clear, or another drain. No extra input pipeline or continuous acc_out port is present.

For continuous tiles, assert drain with the next tile's first pair. After the last tile, publish with drain and no accepted pair. A future array must align local drain pulses with operands and prevent stalled boundary markers from repeatedly draining.

For signed fixed point, F input fractional bits imply 2F result fractional bits; the hardware is unchanged. The tested F=4 example `1.5*(-2)+0.5*1` produces raw result -640, interpreted as -2.5. Rounding/output rescaling is not included.

## Fixed 4x4 Array: RTL Review Stage

`rtl/systolic_4_4_array.v` uses Verilog-2001 generate blocks to instantiate the 16 existing PEs. Input skew uses packed shift registers carrying 9-bit `{valid, byte}` entries; a six-bit shift register distributes drain. It has no top-level parameters. Inputs are two 32-bit buses (`a_in`, `b_in`), two 4-bit valid vectors, and `clk/rst/clear/en/drain_in`. Lane 0 occupies the lowest byte. Supply all four rows of A at the same k and all four columns of B at that k; internal registers provide the 0/1/2/3-cycle skew.

Assert `drain_in` alongside the next tile's first input step. A six-register delay chain supplies four drain row buses, `drain_rows[0]` through `[3]`. Each bus uses bit 3 for column 0 and bit 0 for column 3: a single pulse moves `1000 -> 0100 -> 0010 -> 0001`, with each following row starting one enabled cycle later. Shared delay taps preserve the original 0-6 boundary offsets without duplicating registers. The entire pipeline pauses with en; local drain is gated off during stalls. For final publication, insert a boundary with invalid operands and continue enabled flush steps through diagonal 6. Do not clear between consecutive tiles.

`results[383:0]` packs sixteen signed 24-bit values in row-major order, with PE(0,0) at `[23:0]`. `results_valid[15:0]` identifies publications. Capture valid results every clock, including during stalls, before another tile overwrites each PE's result. No collector, matrix memory, or CPU interface is included.

Run `make compile-array` for syntax/elaboration only. A small directed waveform demo is now available separately; the full array verification suite remains pending. Existing `make test` discovery does not include this demo.

### Array Waveform Demo

Run `make demo-array` to compile and simulate `tb/demo_systolic_4_4_array.v`, or `make wave-array` to run it and open GTKWave. GTKWave is installed locally. The generated trace is `sim/vcd/array_demo.vcd`.

The demo supplies two consecutive k steps (a 4x2 matrix times a 2x4 matrix). In lane order 0/1/2/3: step 0 has A=[1,2,3,4], B=[10,20,30,40]; step 1 has A=[5,6,7,8], B=[11,21,31,41]. It then sends a final drain marker with invalid inputs and keeps en high to flush. All 16 published results are checked, including C[0][0]=65 and C[3][3]=488; missing, duplicate or incorrect publications fail nonzero. This is one directed example, not comprehensive array verification.

In GTKWave, open `demo_systolic_4_4_array`. Add clk, a_in/b_in, a_valid_in/b_valid_in, a_skew0 through a_skew3, b_skew0 through b_skew3, drain_in, drain_row0 through drain_row3, and results_valid. Use decimal for byte data and binary for drain/valid buses. Generated `g_watch_row[n].g_watch_column[m]` scopes contain each PE's operand, valid, S/C, and result signals. Input k0 is accepted at 25 ns and k1 at 35 ns; publications begin at 45 ns and end at 105 ns. Registers change just after rising edges; downstream PEs sample their previous values at those edges.

### Two Back-to-Back 4x4 Matrix Multiplications

`golden/array_matrices.json` contains two signed 4x4 matrix pairs. Python calculates both products using the existing exact `matrix_multiply` model and exports the inputs and expected values. `tb/tb_systolic_4_4_array.v` reads those files and streams four k steps per pair, without gaps or clear between them. Drain accompanies the second pair's first step; an invalid final drain publishes the second output. The testbench no longer calculates expected matrix products.

- `make test-array`: compile/run and print each PE publication immediately.
- `make wave-array-matmul`: run that test and open `sim/vcd/systolic_4_4_array.vcd` in GTKWave. The generated `g_result_view[0]` through `[15]` scopes show each result and valid bit.
- `make test-systolic_4_4_array`: run through the dependency-aware runner; full output is saved in `sim/build/logs/systolic_4_4_array.log`. This test is also discovered by `make test`.

Each console line identifies time, cycle, multiplication number, PE coordinates, result, and expected value. The monitor waits 1 ns after the edge for RTL register updates, so a publication at the 65 ns edge prints at 66 ns. Each PE must publish twice: matrix 1 at cycle 5+row+column and matrix 2 at 9+row+column. All 32 values, counts, and arrival cycles are checked; mismatch, unknown valid, missing/extra publication, or timeout fails nonzero. This is a directed two-matrix test, not the complete random/stall verification suite.

### Python Golden Model to RTL

The flow is `golden/array_matrices.json` -> Python `matrix_multiply` -> `golden/vectors/systolic_4_4_array.txt` -> Verilog testbench comparisons. Each JSON case contains A and B; supply a nonempty list of 4xK A matrices and Kx4 B matrices, with 1 <= K <= 256 and integer values from -128 to 127. The default file still contains two pairs. Python uses signed INT8 operands and 24-bit modular accumulation, matching the fixed array. No NumPy dependency is needed.

- `make golden-array`: calculate and print both C matrices, write the RTL hex file, and save readable matrices/results to `golden/expected/array_results.json`.
- `make test-array`: regenerate vectors, simulate both multiplications, and print/check every publication.
- `make wave-array-matmul`: regenerate, simulate, then open GTKWave.
- `make test-array ARRAY_MATRICES=/path/to/matrices.json`: select your own matrix pairs. The same override works with the dependency-aware `make test-systolic_4_4_array` runner.

The generated file now supports variable K. Each case contains a decimal K header, then 4*K row-major A/B byte pairs (two hexadecimal bytes per line), then 16 row-major C values (six hexadecimal digits each). Regenerate older vectors with `make golden-array`; the old fixed-size A/B/C triple format is superseded. The runner derives testbench-only MATRIX_COUNT from the case count. The loader validates K, signed data, complete input/results and absence of extra data. Standard tests generate fresh build-local files.

### Continuous Matrix Stream

`make test-array-stream` generates and checks 100 consecutive 4x4-by-4x4 multiplications with no input gaps or clears. Seed `20261105` makes the run reproducible. The first eight cases cover zero, left/right identity, all -128, -128 times 127, all 127, alternating extremes, and -1; the remaining 92 use uniformly sampled INT8 operands. Every PE must publish once per multiplication at the expected cycle, and every value must match Python. K remains 4 for every matrix pair; the number of matrix pairs does not change the hardware's K_MAX.

- `make test-array-stream STREAM_COUNT=100 STREAM_SEED=20261105` runs the stream.
- `make wave-array-stream` runs the stream and opens its saved GTKWave trace.
- `sim/build/logs/array_stream.log` contains every PE publication and final summary.
- `sim/build/vectors/array_stream_matrices.json` contains generated inputs; `array_stream_results.json` contains Python C matrices; `array_stream.txt` contains the matching input/expected records.
- `sim/vcd/array_stream.vcd` preserves the stream waveform separately from the default two-matrix trace.

Validated run: 100 matrix products, 1,600 published elements, zero errors. This checks uninterrupted streaming and overlapping output wavefronts; stalls/reset/clear during a stream remain separate coverage.

### Reading the Array Testbench

The testbench follows three steps: load Python vectors, stream matrix operands, then check each publication as it arrives. The checker uses `actual[PE]`, `expected[PE][matrix]`, and `received[PE]`. `received[PE]` starts at zero and selects that PE's next expected matrix result. The core comparison is `actual[index] !== expected[index][received[index]]`; row/column labels are calculated directly from the PE index. Cycle/count, unknown-valid, file-validation, and timeout checks remain in place.

### Counter-Generated Drain in the Testbench

`pe00_count` counts pairs accepted by PE(0,0): en and both lane-0 valid bits must be high. The counter compares against `inner_size[pe00_matrix]`, so each pair can use a different K. On drain, it advances to the next matrix and restarts at 1 if a new product is accepted, otherwise 0. A guard disables drain after final publication. Source loops do not drive drain; they only stream inputs and drop valid bits at the end. The existing row buses delay the boundary across the array. Inspect pe00_count, pe00_matrix and drain_in in GTKWave.

### Different Input Sizes, Always a 4x4 Output

Run `make test-array-sizes` for a continuous mixed-size sequence:

```text
K = 1, 1, 2, 3, 4, 5, 7, 8, 16, 31, 64, 128, 256, 1, 1
A = 4xK, B = Kx4, C = 4x4
```

All 15 products (240 output elements) are checked against Python, including exact arrival cycles and transitions between different K values. Adjacent K=1 cases check consecutive publication edges. The K=256 case uses all -128 operands and expects 4,194,304 in each output element. Seed is STREAM_SEED, default 20261105.

`make wave-array-sizes` opens the saved waveform. Evidence is preserved as `sim/build/logs/array_sizes.log`, `sim/build/vectors/array_sizes_matrices.json`, `array_sizes_results.json`, `array_sizes.txt`, and `sim/vcd/array_sizes.vcd`. Hardware remains fixed at 16 PEs with signed INT8 operands and 24-bit accumulation.
