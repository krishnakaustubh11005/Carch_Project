#!/usr/bin/env python3
"""Build fpga/fw/fpga_demo.c into fpga/fw/fpga_demo.hex (make fpga-fw).

The .hex is committed so the Vivado machine needs no RISC-V toolchain.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import bin2hex
import build_fw

FW, OUT = ROOT / "fw", ROOT / "fpga" / "fw"


def main():
    tool = build_fw.find_prefix()
    if tool is None:
        sys.exit("RISC-V toolchain not found (set RISCV_PREFIX)")
    build = ROOT / "sim" / "build" / "fpga_fw"
    build.mkdir(parents=True, exist_ok=True)
    elf, binary = build / "fpga_demo.elf", build / "fpga_demo.bin"
    for command in (
        [tool + "gcc", *build_fw.CFLAGS, "-I", str(FW), "-T", str(FW / "link.ld"),
         "-o", str(elf), str(FW / "start.S"), str(OUT / "fpga_demo.c"), "-lgcc"],
        [tool + "objcopy", "-O", "binary", str(elf), str(binary)],
    ):
        subprocess.run(command, cwd=ROOT, check=True)
    bin2hex.main([str(binary), str(OUT / "fpga_demo.hex"), "--words", str(build_fw.RAM_WORDS)])
    print(f"wrote {(OUT / 'fpga_demo.hex').relative_to(ROOT)} ({binary.stat().st_size} bytes of code)")


if __name__ == "__main__":
    main()
