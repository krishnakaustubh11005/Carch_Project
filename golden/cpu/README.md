# CPU matrix multiplication baseline

Run from the repository root:

```sh
make test-cpu
```

Run `make test-golden-c` to compare the C and Python models on the host,
including invalid arguments and signed boundary cases, without CPU simulation.

Requires Python 3, Icarus Verilog (`iverilog`, `vvp`), and the RISC-V bare-metal
compiler/binutils. The default toolchain prefix is `riscv64-unknown-elf-`;
override with the `RISCV_PREFIX` environment variable if needed.

The runner compiles the existing `golden/matrix_multiply.c` for RV32IM and
executes it on `external/picorv32/picorv32.v`. The submodule stays unchanged.
There is no systolic accelerator or accelerator driver. PicoRV32's internal
standard integer multiply/divide units are enabled; external PCPI is disabled.

Five deterministic cases cover a hand-checkable 2x2 example, signed rectangular
inputs, the maximum supported K=256 with -128 operands, and random signed
3x5 by 5x4 and 8x8 matrices. Expected outputs come from `golden/model.py`.
Firmware compares every result and reports failure through a simulation-only
status register. Traps, invalid accesses, and timeouts fail the run.

Cycle counts bracket the C function call using `rdcycle`; they include call and
counter overhead but exclude result checking. They describe this simulated CPU
configuration with its simple registered RAM interface, not host execution
time or FPGA timing. No accelerator speedup is measured here.

`start.S` sets up the stack; `link.ld` places firmware in 64 KiB RAM.
The testbench zero-initializes RAM, including BSS, before loading firmware.
Generated vectors, ELF, binary, hex, and simulation executable are under
`sim/build/cpu/`.
