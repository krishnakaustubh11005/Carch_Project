#!/usr/bin/env python3
"""Build the PicoRV32 test firmware (fw/) into a $readmemh RAM image.

    fw/start.S fw/*.c --gcc--> fw.elf --objcopy--> fw.bin --bin2hex--> fw.hex

The toolchain prefix comes from --prefix, $RISCV_PREFIX, or the first of
riscv64-unknown-elf- / riscv32-unknown-elf- found on PATH. A 64-bit gcc is
fine: -march=rv32im -mabi=ilp32 selects the 32-bit target (ENABLE_FAST_MUL
in soc_top provides the M extension's mul).
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bin2hex

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = ("riscv64-unknown-elf-", "riscv32-unknown-elf-")
CFLAGS = ["-march=rv32im", "-mabi=ilp32", "-O2", "-ffreestanding", "-nostdlib",
          "-Wall", "-Wextra", "-Werror", "-g"]
RAM_WORDS = 1 << 14


def find_prefix(prefix=None):
    for candidate in (prefix, os.environ.get("RISCV_PREFIX"), *PREFIXES):
        if candidate and shutil.which(candidate + "gcc"):
            return candidate
    return None


def build(root=ROOT, out_dir=None, prefix=None, timeout=120, full=False):
    """full=True defines FW_FULL (larger benchmark jobs).

    Returns (status, detail): ("ok", hex path), ("missing", reason) or
    ("failed", build log).
    """
    root = Path(root)
    out_dir = Path(out_dir) if out_dir else root / "sim" / "build" / "fw"
    tool = find_prefix(prefix)
    if tool is None:
        return "missing", "RISC-V toolchain not found (set RISCV_PREFIX)"
    fw = root / "fw"
    out_dir.mkdir(parents=True, exist_ok=True)
    elf, binary, hexfile = out_dir / "fw.elf", out_dir / "fw.bin", out_dir / "fw.hex"
    sources = [fw / "start.S"] + sorted(fw.glob("*.c"))
    steps = [
        [tool + "gcc", *CFLAGS, *(["-DFW_FULL"] if full else []),
         "-T", str(fw / "link.ld"), "-o", str(elf), *map(str, sources), "-lgcc"],
        [tool + "objcopy", "-O", "binary", str(elf), str(binary)],
    ]
    log = ""
    for command in steps:
        try:
            result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            return "failed", log + f"$ {' '.join(command)}\n{error}\n"
        log += f"$ {' '.join(command)}\n{result.stdout}"
        if result.returncode != 0:
            return "failed", log
    try:
        bin2hex.main([str(binary), str(hexfile), "--words", str(RAM_WORDS)])
    except SystemExit as error:
        return "failed", log + f"bin2hex: {error}\n"
    return "ok", hexfile


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--prefix", help="toolchain prefix, e.g. riscv64-unknown-elf-")
    parser.add_argument("--out", type=Path, help="output directory (default sim/build/fw)")
    parser.add_argument("--full", action="store_true", help="add the larger benchmark jobs")
    args = parser.parse_args(argv)
    status, detail = build(out_dir=args.out, prefix=args.prefix, full=args.full)
    if status != "ok":
        sys.exit(f"firmware build {status}: {detail}")


if __name__ == "__main__":
    main()
