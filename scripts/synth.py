#!/usr/bin/env python3
"""FPGA synthesis check: run Yosys synth_xilinx (7-series) on each block.

Each block is flattened before synthesis so that constant port ties reach the
memories (scratchpads tie the unused write port of dual_port_ram to zero; only
then does the RAM become 1-write/1-read and map to block RAM).

A block fails if Yosys errors, a latch appears, its block-RAM count differs
from the expected count, or it uses more flip-flops than its budget. The FF
budget catches a memory that was silently built from flip-flops.

The main data RAM (dual_port_ram with both ports writing) is not checked:
Yosys 0.9 has no Xilinx mapping for two write ports. Vivado or a newer Yosys
maps it to block RAM.

Logs and reports go to sim/build/synth/<block>.log. LUT/FF counts from Yosys
are estimates; timing needs Vivado or nextpnr place-and-route.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
BUILD = ROOT / "sim/build/synth"

# block: (expected block-RAM cells, maximum flip-flops)
BLOCKS = {
    "scratchpad_a":       ({"RAMB18E1": 4}, 16),
    "scratchpad_b":       ({"RAMB36E1": 1}, 16),
    "c_store":            ({"RAMB36E1": 4}, 16),
    "fetch_unit":         ({}, 200),
    "c_copier":           ({}, 64),
    "pe_booth_csa":       ({}, 128),
    "systolic_4_4_array": ({}, 2048),
    "tile_sequencer":     ({}, 2048),
    "accel_regs":         ({}, 512),
    "job_controller":     ({}, 128),
    "matmul_accel":       ({"RAMB18E1": 4, "RAMB36E1": 5}, 3072),
}
RAM_CELLS = ("RAMB18E1", "RAMB36E1", "RAM32M", "RAM64M", "RAM32X1D", "RAM64X1D",
             "RAM128X1D", "RAM256X1S")
FF_CELLS = ("FDRE", "FDSE", "FDCE", "FDPE")
LATCH_CELLS = ("LDCE", "LDPE", "$_DLATCH_N_", "$_DLATCH_P_")


def synth(yosys, block, sources, timeout):
    BUILD.mkdir(parents=True, exist_ok=True)
    log = BUILD / f"{block}.log"
    report = BUILD / f"{block}.stat"
    script = (f"read_verilog {' '.join(str(s) for s in sources)}; "
              f"synth_xilinx -flatten -top {block}; "
              f"tee -q -o {report} stat; check -assert")
    result = subprocess.run([yosys, "-q", "-l", str(log), "-p", script],
                            capture_output=True, text=True, timeout=timeout)
    cells = {}
    if report.exists():
        for line in report.read_text().splitlines():
            match = re.match(r"\s+(\S+)\s+(\d+)$", line)
            if match:
                cells[match.group(1)] = int(match.group(2))
    return result, cells, log


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--yosys", default=os.environ.get("YOSYS") or "yosys")
    parser.add_argument("--block", action="append", choices=sorted(BLOCKS),
                        help="check only this block (repeatable)")
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()

    if shutil.which(args.yosys) is None:
        print(f"FAIL    yosys not found ({args.yosys}); set YOSYS=path")
        return 2
    sources = sorted(RTL.glob("*.v"))
    blocks = args.block or list(BLOCKS)
    failures = 0
    print(f"{'block':20} {'result':6} {'LUT':>7} {'FF':>6}  block RAM")
    for block in blocks:
        expected_ram, ff_budget = BLOCKS[block]
        try:
            result, cells, log = synth(args.yosys, block, sources, args.timeout)
        except subprocess.TimeoutExpired:
            print(f"{block:20} FAIL   timeout after {args.timeout:.0f} s")
            failures += 1
            continue
        luts = sum(n for name, n in cells.items() if name.startswith("LUT"))
        ffs = sum(cells.get(name, 0) for name in FF_CELLS)
        rams = {name: cells[name] for name in RAM_CELLS if cells.get(name)}
        latches = sum(cells.get(name, 0) for name in LATCH_CELLS)

        problems = []
        if result.returncode != 0:
            problems.append(f"yosys exit {result.returncode}, see {log.relative_to(ROOT)}")
        if latches:
            problems.append(f"{latches} latch cells")
        if rams != expected_ram:
            problems.append(f"block RAM expected {expected_ram or 'none'}, got {rams or 'none'}")
        if ffs > ff_budget:
            problems.append(f"{ffs} FFs > budget {ff_budget} (memory built from FFs?)")

        ram_text = ", ".join(f"{n} x {name}" for name, n in rams.items()) or "-"
        status = "FAIL" if problems else "PASS"
        print(f"{block:20} {status:6} {luts:7} {ffs:6}  {ram_text}")
        for problem in problems:
            print(f"    {problem}")
        failures += bool(problems)

    print(f"Summary: {len(blocks) - failures} PASS, {failures} FAIL "
          f"(Xilinx 7-series, Yosys estimates; logs in {BUILD.relative_to(ROOT)})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
