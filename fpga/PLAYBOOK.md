# Carch: PYNQ-Z2 Demo Day Playbook

Offline copy of the playbook doc. Everything you need is in this `fpga/` folder.

## 1. Goal

In 4 hours, run the full Carch SoC (PicoRV32 + 64 KB RAM + 4x4 systolic
accelerator) on the PYNQ-Z2 and show the multiplied matrices read back from
the live chip. Show, in order:

1. **It fits and meets timing:** Vivado utilization + timing reports for
   `xc7z020clg400-1` at 50 MHz.
2. **It runs:** LD1 lights for PASS (accelerator result = CPU's software result).
3. **The numbers:** A, B, C and the cycle counts, captured inside the FPGA by
   the ILA over the JTAG cable.
4. **How it works:** `make view-cpu`, `make view-accel` if asked.

No extra hardware: one micro-USB cable powers, programs and reads back.

## 2. 4-hour timeline

| Time | Do this | Done when |
| --- | --- | --- |
| 0:00-0:15 | Copy Carch to the laptop, set jumpers, plug in | Red power LED on, Vivado opens |
| 0:15-1:00 | Run `build.tcl`; read the defense sections meanwhile | `WNS` >= 0 and `wrote fpga_top.bit` |
| 1:00-1:20 | Run `hw.tcl`, press BTN0 at ARMED | Matrices print, PASS, LD1 on |
| 1:20-1:40 | Save evidence: report screenshots, printed matrices, ILA waveform, LED photo | One folder |
| 1:40-2:30 | Buffer: 25 MHz rebuild or driver fix | Same checks |
| 2:30-3:30 | Practise demo script + questions out loud | Explain diagram without notes |
| 3:30-4:00 | Full dry run from powered-off board | Demo under 10 min |

## 3. Files

| File | What it is |
| --- | --- |
| `fpga_top.v` | Board wrapper: MMCM (125 -> 50 MHz), reset sync, unchanged `soc_top`, ILA taps, LEDs, UART text |
| `uart_result_bridge.v` | Result words -> hex text on Pmod JA pin 1 (only with a USB-UART adapter) |
| `pynq_z2.xdc` | Pins + clock constraint (pins from memory: verify) |
| `fw/fpga_demo.hex` | Prebuilt firmware (no RISC-V compiler needed); source `fw/fpga_demo.c` |
| `build.tcl` | Synth, place, route, reports, bitstream, ILA probes (`.ltx`) |
| `hw.tcl` | Program board, arm ILA, capture, print matrices |
| `sim.tcl`, `tb_fpga_top.v` | Simulation fallback: RTL, post-route funcsim, timing sim |

## 4. Step by step

1. **Copy files.** Pull `kk_new_branch` or copy the Carch folder (USB stick).
   Use a path with **no spaces** (`C:/Carch`, `~/Carch`).
2. **Board.**
   1. Boot-mode jumper JP1 (near SD slot): **JTAG**.
   2. Power jumper (near power switch): **USB**.
   3. Micro-USB into **PROG/UART**, switch ON. Red LED lights.
3. **Shell.** Windows: Start menu -> "Vivado 20xx.x Tcl Shell". Linux:
   `source <Xilinx>/Vivado/<ver>/settings64.sh`. Then `cd` to Carch.
4. **Build (30-45 min).**

       vivado -mode batch -source fpga/build.tcl

   Look for `timing: WNS = X ns`. **>= 0 is good.** Negative -> 25 MHz:

       vivado -mode batch -source fpga/build.tcl -tclargs 40

5. **Program + capture (2 min).**

       vivado -mode batch -source fpga/hw.tcl

   At `ARMED: press BTN0`, press BTN0 once. Prints A, B, C, cycles, PASS.
6. **Capture again** without reprogramming:

       vivado -mode batch -source fpga/hw.tcl -tclargs noprog

Outputs in `fpga/out/`: `fpga_top.bit`, `fpga_top.ltx`, `utilization.rpt`,
`timing_summary.rpt`, `power.rpt`, `capture.csv`.

## 5. Seeing the results

The firmware multiplies 4x4 A by 4x4 B on the accelerator, checks it against
a software matmul, then writes A, B, C and the cycle counts to the result
port (0x8000_0000): 42 words.

- The ILA watches `dbg_result` (32 bits) and `dbg_valid`, 2048 samples at 50 MHz.
- Triggers on the first `dbg_valid = 1`; the dump lasts ~660 clocks (13 us),
  so one trigger catches everything.
- BTN0 resets the CPU; firmware lives in block RAM, so it reruns without
  reprogramming.
- `hw.tcl` uploads over JTAG, saves `capture.csv`, decodes and prints.

Expected output (from simulation):

```
matrix A  (4 x 4)            matrix B  (4 x 4)
[  1   2   3   4 ]           [  1   0   2  -1 ]
[ -1   0   1   2 ]           [  0   1   1   0 ]
[  5  -3   2   0 ]           [  3  -2   0   1 ]
[  0   1  -2   3 ]           [  1   1  -1   2 ]

matrix C = A x B  (4 x 4)
[ 14   0   0  10 ]
[  4   0  -4   6 ]
[ 11  -7   7  -3 ]
[ -3   8  -2   4 ]

benchmark 4x4x4
  software (CPU only) : 5661 cycles
  accelerator         : 151 cycles (fetch 16, compute 35)
  speed-up            : 37.5x
final result word 0x00000001 -> PASS
```

| LED | Meaning |
| --- | --- |
| LD0 | Blinking (~0.7 s): clock running |
| LD1 | PASS (last result word was 1) |
| LD2 | FAIL code, CPU trap or bus error |
| LD3 | UART bridge overflow (should never light) |

**Live waveform (GUI):** Vivado -> Open Hardware Manager -> Open Target ->
Auto Connect -> Program with `fpga_top.bit` + `fpga_top.ltx` -> ILA trigger
`dbg_valid == 1` -> Run -> press BTN0. Set `dbg_result` radix to hex.

## 6. If something goes wrong

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| WNS negative | Single-cycle Booth MAC too slow for 50 MHz | `build.tcl -tclargs 40` (25 MHz). Say "next step: pipeline the PE" |
| Pin / IOSTANDARD error | XDC pins from memory | Compare with PYNQ-Z2 master XDC, edit `pynq_z2.xdc` |
| Error about `fw_path.vh` / `.hex` | Spaces in path, or folder moved | Path without spaces, rebuild |
| No hardware target | Cable drivers missing | Linux: `<Vivado>/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers` as root. Windows: rerun installer with cable drivers. Replug |
| Timeout after ARMED | BTN0 not pressed / CPU not running | `hw.tcl -tclargs noprog`, press BTN0; check LD0 blinks |
| LD0 not blinking | Wrong clock pin, or JP1 not on JTAG | Check H16 in master XDC, check jumper |
| Wrong C / FAIL | Real hardware bug | Show honestly; simulation still proves the design |

**Fallback ladder**

1. Board + ILA matrices + reports.
2. Board + LEDs (LD1 = PASS) + reports + simulated matrices.
3. No board: `build.tcl -tclargs 20 sim`, then `sim.tcl -tclargs func`
   (or `timing` for real wire delays; add `gui` for waves).
4. No Vivado: `make fpga-rtl-sim`, `make test-soc_top`, visualizers.

## 7. Demo script (~10 min)

Before the evaluator arrives: board programmed, reports open, Tcl shell in
Carch, visualizers in a browser.

1. **Pitch (30 s):** "A RISC-V SoC with our own 4x4 systolic matrix-multiply
   accelerator, radix-4 Booth multipliers and carry-save accumulation,
   running on this PYNQ-Z2."
2. **Block diagram (2 min):** section 8.
3. **It fits (1 min):** `utilization.rpt` vs 7020 totals; `timing_summary.rpt` WNS >= 0.
4. **Live run (2 min):** `hw.tcl -tclargs noprog`, BTN0, matrices print, LD1 on.
5. **Check by hand (1 min):** C[0][0] = 1x1 + 2x0 + 3x3 + 4x1 = 14.
6. **Speed-up (1 min):** 151 vs 5661 cycles, ~37x; the array itself computes in 35.
7. **Verification (1 min):** unit testbenches, Python golden model, full-SoC
   firmware test, Verilator lint, Yosys synth check, board.
8. **Limits / next steps (1 min):** question 20.

## 8. The design in two minutes

PicoRV32 and a matmul accelerator share one 64 KB dual-port block RAM. The
CPU sets up a job; the accelerator fetches its own data, computes, writes C back.

```
  board 125 MHz -> MMCM -> 50 MHz        BTN0 -> reset sync
                     |
  +------------------v-------------------------------------------+
  | soc_top                                                      |
  |  PicoRV32 (RV32IM) --bus--> decoder                          |
  |     |  0x0000_0000  RAM port A   (code + data, 64 KB BRAM)   |
  |     |  0x4000_0000  accelerator registers (MMIO)             |
  |     |  0x8000_0000  result port  ------------> ILA / UART    |
  |                                                              |
  |  matmul_accel --RAM port B--> same 64 KB RAM                 |
  |    fetch unit -> scratchpad A / B -> tile sequencer          |
  |    -> 4x4 systolic array (16 Booth/CSA PEs) -> C store       |
  |    -> C copier -> RAM                                        |
  +--------------------------------------------------------------+
```

**One job:**

1. CPU writes A and B (int8) to RAM.
2. CPU writes M, N, K and the A/B/C addresses to the registers, then START.
3. Fetch unit reads A, B through port B into two on-chip scratchpads.
4. Tile sequencer feeds one 4x4 output tile at a time: A from the left, B from the top.
5. Each PE keeps its own sum (output-stationary); after K steps it drains into the C store.
6. C copier writes C (int32) to RAM, sets DONE; CPU polls STATUS (or interrupt).

**Inside one PE:**

- Radix-4 Booth: 8 partial-product rows -> 4.
- FA/HA compressor tree (carry-save) reduces them without carry waits.
- Accumulator kept as sum + carry vectors; one carry-propagate add only at drain.
- 24-bit accumulator: 16-bit product + 8 bits headroom (256 adds); K <= 64, never overflows.

## 9. Likely questions

**Architecture**

1. **Why systolic?** Operands load once and are reused as they move; 16 MACs
   per clock from 4 A + 4 B inputs. Neighbour-only wiring routes well on FPGA.
2. **Why output-stationary?** Each PE owns one C value; the accumulator never
   moves. Weight-stationary suits reusing one weight matrix; we load fresh A and B.
3. **Why dual-port RAM, no arbiter?** Port A = CPU, port B = accelerator, both
   every clock, no arbitration. Maps straight to FPGA true dual-port BRAM;
   the accelerator fetches its own data like a small DMA.
4. **Why scratchpads?** The array needs 4 A + 4 B values per clock; main RAM
   gives one word per port per clock in the wrong layout. Banked scratchpads
   give one array input per read.
5. **Bigger than 4x4?** Hardware tiling over 4x4 output tiles; M, N, K = 1..64;
   ragged edges zero-padded.
6. **Why PicoRV32?** Small (~2k LUTs), well verified, open, simple valid/ready bus.

**Arithmetic**

7. **Why radix-4 Booth?** Halves partial products (8 -> 4), smaller/shallower
   tree, signed natively.
8. **Why carry-save accumulation?** No 24-bit carry ripple every cycle; pay one
   full add only at drain.
9. **Why 24 bits?** 16-bit product + log2(256) = 8 bits. K <= 64 gives margin.
   Sign-extended to 32 bits in RAM.
10. **Why not DSP blocks?** We wanted to build and show the multiplier
    structure; DSP48 is the natural next version.

**FPGA**

11. **Why 50 MHz?** Critical path = single-cycle Booth multiply + compressor in
    the PE. Pipelining would raise it.
12. **MMCM?** On-chip clock manager: 125 MHz x 8 = 1000 MHz VCO, / 20 = 50 MHz.
13. **Reset synchronizer?** Button is asynchronous; two flops stop
    metastability; 16-clock hold after MMCM lock.
14. **Firmware into FPGA?** `$readmemh` -> Vivado sets BRAM initial contents
    in the bitstream.
15. **Does the ILA change the design?** It only watches registered copies of
    the result port, uses a few BRAMs, does not touch the datapath.
16. **Why not the ARM (PS)?** Design is self-contained in PL, portable to any
    7-series FPGA. AXI link to the ARM is future work.

**Verification and results**

17. **How do you know it's right?** Firmware compares every C value with a
    software matmul; PASS only if all match. Testbenches compare with a
    Python golden model.
18. **What was tested?** Every block in its own testbench, whole jobs through
    registers, firmware on the full SoC: 1x1 to 64x64x64, extremes
    (-128 x -128), unaligned addresses, errors, abort mid-job.
19. **Is 37x fair?** For 4x4x4 vs plain C on PicoRV32 (several cycles per
    instruction). Bigger jobs give bigger speed-ups (`make test-soc-full`).
20. **Limits / next steps?** Max 64; no fetch/compute overlap; single-cycle PE
    limits clock; no DSP; not linked to ARM. Next: pipeline PE, double-buffer
    scratchpads, AXI interface for PYNQ/Python control.

## 10. Numbers to remember

Fill the last column from `utilization.rpt` / `timing_summary.rpt`.

| Item | Value | Your build |
| --- | --- | --- |
| Part | Zynq XC7Z020, `xc7z020clg400-1` | |
| Chip size | 53,200 LUT, 106,400 FF, 140 BRAM36, 220 DSP | |
| Our LUTs | ~11,000 est. (~20%) | |
| Our BRAM36 | ~25 est. (16 main RAM + scratchpads/C store) + ~2 ILA | |
| Clock | 125 MHz board, 50 MHz system | |
| WNS | must be >= 0 | |
| CPU | PicoRV32 RV32IM, ~2k LUT | |
| RAM | 64 KB true dual-port BRAM, 1-cycle read | |
| Array | 4x4 = 16 PEs, 16 MACs/clock | |
| Types | int8 in, 24-bit acc, int32 out | |
| Max job | M, N, K each 1..64 | |
| Peak at 50 MHz | 800 M MAC/s | |
| Demo 4x4x4 | 151 vs 5661 cycles, ~37x | |
| Result dump | 42 words, ~660 clocks | |
| Address map | RAM 0x0, accel 0x4000_0000, result 0x8000_0000 | |
