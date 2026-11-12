# Processor-driven accelerator integration

PicoRV32 now executes a bare-metal RV32IM program that drives the MMIO
accelerator with ordinary loads and stores. The program checks CPU-only and
accelerator results against the same Python-generated expected matrices.

## Source layout

| Source | Role |
|---|---|
| `rtl/picorv32_accelerator.v` | CPU, address decoder, MMIO peripheral, request-gap adapter |
| `external/picorv32/` | Pinned upstream processor submodule |
| `sw/accelerator/driver.h`, `driver.c` | Fixed-4x4 MMIO C driver |
| `sw/firmware/start.S` | Stack initialization, BSS clearing, call to main |
| `sw/firmware/link.ld` | 64 KiB RAM image, sections, stack reservation |
| `sw/firmware/main.c` | CPU baseline, accelerator calls, checks, cycle reporting |
| `tb/system_picorv32_accelerator.v` | Simulated RAM and pass/fail reporting |
| `scripts/run_processor.py` | Golden vectors, compiler invocation, image loading, simulation |
| `scripts/tests/test_processor.py` | Real integration test and illegal-instruction failure test |

Firmware belongs under `sw/`; mathematical reference generation remains under
`golden/`. The system testbench uses a `system_` prefix because it requires
firmware and an external CPU checkout, rather than the generic module runner.

## Run

Prerequisites are Python 3, Icarus Verilog (`iverilog`, `vvp`), and a bare-metal
RISC-V GCC/binutils installation supporting RV32IM with the ILP32 ABI.
Initialize the pinned processor source after cloning:

```sh
 git submodule update --init --recursive
 make test-processor
```

The default compiler prefix is `riscv64-unknown-elf-`. Override it when needed:

```sh
RISCV_PREFIX=riscv32-unknown-elf- make test-processor
make test-processor ACCELERATOR_MATRICES=golden/array_matrices.json
make wave-processor
```

Custom matrices use the existing JSON `cases`/`A`/`B` format and must be 4x4.
`make wave-processor` additionally requires GTKWave. To generate the waveform
without opening a GUI:

```sh
python3 scripts/run_processor.py --vcd
```

Outputs are in `sim/build/processor/`: generated `cases.h`, expected answers,
ELF, binary, word-oriented hex RAM image, compiled simulation, and `run.log`.
The waveform is `sim/vcd/processor_accelerator.vcd`. `--build-dir` selects an
isolated build directory for integration tests. Generated artifacts are ignored
by Git when using the default directory.

## System and address map

```text
PicoRV32 (RV32IM)
    ├── 0x10000000–0x100000FF → gap adapter → accelerator_mmio
    │                                        └── accelerator_4x4
    │                                              └── systolic array
    └── other addresses → external memory interface → testbench RAM/reports
```

| Address | Meaning |
|---|---|
| `0x00000000–0x0000FFFF` | 64 KiB unified instruction/data RAM in the testbench |
| `0x10000000–0x100000FF` | Accelerator registers; see the MMIO guide |
| `0x20000000` | Simulation-only CPU cycle report |
| `0x20000004` | Simulation-only accelerator total-cycle report |
| `0x20000008` | Simulation-only completion/failure status |

The hardware interconnect exposes a native memory port for all non-accelerator
addresses. The testbench supplies registered, byte-writeable RAM and reporting
registers; other external accesses fail simulation. A future FPGA top must
provide real RAM and replace the simulation reporting interface.

The processor enables its standard integer multiply/divide units and uses
software-visible cycle counters. IRQ and external coprocessor responses are
tied inactive. The accelerator is memory-mapped, not an instruction extension.
PicoRV32 is pinned at `ef203c2b0a3fb793280f5114941416c425c5b461`.

## Request adapter

The peripheral requires a valid-low edge between accesses. The interconnect
inserts that edge after every peripheral acknowledgement, independently of
whether the CPU lowers its own valid. New CPU requests wait through the gap;
RAM requests route separately. This preserves the peripheral's one-response,
one-side-effect behavior without modifying the CPU or accelerator controller.

## Firmware behavior

Startup sets the stack to the end of RAM and clears BSS. The linker reserves
at least 4 KiB below the stack top and rejects oversized firmware. Code and
initialized data are loaded directly into their execution addresses by the
simulation loader; there is no operating system or C standard-library runtime.

For each matrix pair, main:

1. Runs a sequential triple-loop C multiplication and measures its cycles.
2. Calls `accelerator_matmul`, measuring the whole driver invocation.
3. Compares all sixteen CPU outputs and all sixteen accelerator outputs against
   Python results. K=4 guarantees the int32 CPU sum equals signed 24-bit results.
4. Reports both measured intervals only after all comparisons pass.

The driver checks busy, writes sixteen A words and sixteen B words, starts the
operation, polls at most 1000 times, and reads sixteen sign-extended results.
It returns 0 for success, -1 when already busy, and -2 on polling timeout.
Its caller supplies valid arrays of sixteen elements; it is a single-caller,
fixed-address driver for this in-order system, not a portable OS driver.
The default fixture runs eight consecutive jobs without resetting the system.

Reporting status codes: 1 = complete; 2 = driver failure; 3 = CPU mismatch;
4 = accelerator mismatch. CPU traps, invalid accesses, malformed reports,
missing case reports, and timeout also fail the simulation. The Python runner
requires both a zero process exit and explicit success markers. Automated tests
also corrupt the entry instruction and verify that execution traps and fails.

## Cycle-count interpretation and limits

The CPU interval brackets the sequential multiplication function. The accelerator
interval includes the driver's busy check, input loads/stores, start, polling,
and output reads. Neither interval includes result comparison, reporting, boot,
or Python compilation/simulation time. Both include call/counter overhead.

With the default compiler/settings and registered RAM, the observed intervals
are 5388 CPU cycles and 1422 accelerator-driver cycles per 4x4 job. These are
simulated cycle counts for this implementation, not FPGA timing measurements or
a claim of optimal CPU software. Compiler/toolchain changes can change them.

This stage does not implement FPGA RAM, an external bus fabric, interrupts,
DMA, caches, larger matrices, or tiling. Generic `make test` continues to cover
RTL modules. `make test-processor` explicitly runs the full firmware flow;
`make test-tooling` includes the real processor integration test when the
checkout/toolchain are available, otherwise reports that test as skipped.
