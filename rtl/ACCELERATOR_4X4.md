# Register-backed 4x4 accelerator

`accelerator_4x4.v` wraps `systolic_4_4_array` with input/output register
storage and a controller. It performs one signed INT8 4x4 by 4x4 multiplication
per accepted start. Results are signed 24-bit row-major values. The existing
array and its PEs are unchanged. This is synthesizable hardware, not firmware.

## Interface

All writes and control acceptance occur on the rising clock edge. Drive inputs
before that edge. Reset is synchronous, active high, and has highest priority.

| Signal | Direction | Meaning |
|---|---|---|
| `clk`, `rst` | Input | Clock and synchronous reset |
| `load_we` | Input | Write one input byte when not busy |
| `load_b` | Input | Select A (`0`) or B (`1`) |
| `load_addr[3:0]` | Input | Row-major address, `4*row + column` |
| `load_data[7:0]` | Input | Signed two's-complement input byte |
| `start` | Input | Request an operation when not busy and `load_we=0` |
| `busy` | Output | Operation active, including preparation and collection |
| `done` | Output | Sticky completion; clears on reset or accepted start |
| `result_addr[3:0]` | Input | Row-major result address |
| `result_data[23:0]` | Output | Asynchronous read of signed result storage |

A/B storage each contain sixteen 8-bit registers. C storage contains sixteen
24-bit registers. Reset zeroes all storage and discards active work. After
reset, reload inputs before computing unless zero inputs are intended.

Writes while busy and starts while busy are ignored, not queued. When idle or
finished, a simultaneous write and start performs only the write; start must
be requested again later. Pulse start for one clock. A held-high start can
request another operation when the device becomes available.

Done remains high during input loading after completion. Starting another
operation clears done but retains old C values until new results overwrite
them. Read a completed matrix only while done is high and busy is low; reads
while busy can expose a mixture of old and new values. A/B persist across
operations, permitting repeated computation without reloading. There is no
input-loaded mask; supplying complete matrices is the caller's responsibility.

## Control sequence

1. **IDLE/DONE:** accept input writes or a start request.
2. **CLEAR:** assert array clear for one edge; reset the operation's result mask
   on start acceptance. Busy is high during preparation.
3. **FEED:** send four source steps, k=0 through 3. Lane i supplies A[i][k];
   lane j supplies B[k][j]. All input valid bits are high. The array supplies
   its own lane skew; the wrapper does not duplicate those delays.
4. **DRAIN:** send one boundary marker with invalid input lanes.
5. **COLLECT:** keep array enable high with invalid inputs while the boundary
   travels through the mesh. Capture results and OR valid bits into a 16-bit
   received mask throughout the active operation.
6. **DONE:** when all sixteen mask bits, including this edge's arrivals, are
   set, deassert busy and assert done. The last result writes on that same edge.

The array registers its publications. The wrapper samples those registered
values on the following edge. Completion is based on observed valid bits,
not a fixed delay counter. In the current implementation completion occurs
13 clock periods after the accepting start edge; callers should use done.

Small register arrays provide four A reads and four B reads per feed step.
This interface does not imply single-port block RAM. A later BRAM design will
need a compatible banking/read schedule. There is no processor bus, DMA,
variable K, tiling, external stall input, or overlap between operations yet.

## Verification and commands

```sh
make test-accelerator
make wave-accelerator                 # GTKWave required
make test-accelerator ACCELERATOR_MATRICES=golden/array_matrices.json
```

The default fixture, `golden/accelerator_matrices.json`, contains eight cases:
zero, identity, signed extremes, and four deterministic random pairs (seed 42).
The runner calculates expected results with `golden/model.py`; no RTL-derived
answers are used. Custom fixtures use the existing `cases` / `A` / `B` JSON
format and must have K=4. Other shapes are rejected.

The testbench runs six successful operations per case: a normal operation,
a repeat without reloading, and recovery runs after reset in CLEAR, FEED,
DRAIN, and COLLECT. It attempts writes and starts while busy, checks write/start
priority, sticky completion, output stability, reset-zeroed results, and every
computed output. The default run checks 768 matrix elements. A bounded wait
fails when completion does not arrive; it does not hang indefinitely.

Artifacts:

- `sim/build/logs/accelerator_4x4.log`: compiler and simulation transcript.
- `sim/build/vectors/accelerator_4x4.txt`: inputs and Python expected outputs.
- `sim/build/vectors/accelerator_4x4_results.json`: readable golden results.
- `sim/vcd/accelerator_4x4.vcd`: wrapper-interface waveform.

The generic `make test` also discovers the wrapper test, using ARRAY_MATRICES
along with the other array tests. The dedicated target selects the eight-case
wrapper fixture. Strict project checks still report any unrelated pending RTL.
No FPGA timing/resource measurements are claimed by simulation verification.
