# Carch program runner

Write a C program in the browser, then simulate it or run it on the PYNQ-Z2.
It always runs on **two** systems:
- the **CPU-only** bitstream (`fpga/out_baseline`)
- the **CPU + accelerator** bitstream (`fpga/out`)

You get one report comparing them.

    make user-ui            # then open http://localhost:8765 (Windows browser)

The program can also be run from the command line:

    python3 fpga/user/carch_user.py sim   fpga/user/examples/1_matmul.c
    python3 fpga/user/carch_user.py board fpga/user/examples/1_matmul.c

## Writing a program

Define `uint32_t job(void)` and include `carch.h`. The library gives you:

| Function | What it does |
|---|---|
| `matmul(A, B, C, M, K, N)` | C = A×B: int8 inputs, int32 result, row-major. Uses the accelerator when the bitstream has one and M, K, N ≤ 64; otherwise the CPU loop. The same call works on both systems |
| `matmul_cpu(...)` | Always the CPU loop |
| `has_accel()` | 1 on the accelerator bitstream |
| `print_value(id, v)` | Show a value in the report (up to 48) |
| `region_begin(id)` / `region_end(id)` | Time part of your program (ids 0–7) |
| `rand_seed`, `rand_u32`, `rand_i8` | Pseudo-random numbers, the same sequence on both systems |
| `checksum(p, bytes)` | Hash of a buffer: return it from `job()` so both systems' answers can be compared |
| `cycles()`, `instructions()` | Raw counters |

**Limits**
- **Memory:** 64 KB RAM. Code, constants and globals get 0x0000–0xDFFF; the stack gets 8 KB. Keep big arrays `static`, not local.
- **No hardware divide:** PicoRV32 is built without one. `/` and `%` work, but call a slow software routine. The build uses `-mno-div`.
- **Report size:** the measurements are sent at the end of the run in one burst, which must fit the 4096-sample ILA window. 48 prints and 8 regions fit.

## What happens

1. **build:** gcc (rv32im) builds `start.S` + `carch.c` + your file into `.hex` (for simulation) and `.mem` (for `updatemem`). The stack is at the top of RAM (`link.ld`).
2. **sim:** Icarus runs `tb_user.v` (`fpga_top` with `ENABLE_ACCEL` 0 and 1), about 1 min per million clocks.
3. **board:**
   - **Load the program.** `updatemem` writes it into the RAM of the existing bitstreams. The `ram.mmi` RAM map comes from `write_mmi.tcl`, which `build.tcl` now runs on every build. This takes seconds, with no rebuild; the hardware stays exactly the one you measured.
   - **Run it.** `board.tcl` (Vivado batch) programs each bitstream, arms the ILA, pulses the VIO reset and saves the capture.
   - **Where it runs.** This happens on the Windows copy of the repo (`CARCH_WIN_ROOT`, default `/mnt/c/carch`) with Windows Vivado (`CARCH_VIVADO_BIN`). Close the hardware target in the Vivado GUI first: only one program can hold the JTAG cable.
4. **report:** whole-program and in-`matmul` speed-up, Amdahl limit, cycles, instructions, CPI, fetch/compute/overhead, array use, regions, prints, and FPGA utilization/timing/power (from each build's `summary.txt`).

Each run is saved in `fpga/user/runs/<time>/` (`job.c`, build output, `results.json`). Board captures go to `fpga/user_runs/` in the Windows copy.

After a board run the PYNQ-Z2 holds your program. Run `run_program` in `fpga/run.tcl` to go back to the job firmware.

## Files

| File | Role |
|---|---|
| `carch.h`, `carch.c` | API and framework: timing, matmul dispatch, report burst |
| `start.S`, `link.ld` | Start-up code and memory layout for user programs |
| `examples/*.c` | matmul, neural net, CPU-only (speed-up 1×), chain of small matmuls |
| `carch_user.py` | Build / simulate / board pipeline and decoding |
| `server.py`, `index.html` | The web page and its local server (127.0.0.1 only) |
| `tb_user.v` | Icarus testbench |
| `write_mmi.tcl`, `board.tcl` | Vivado: RAM map for updatemem; program + capture |
