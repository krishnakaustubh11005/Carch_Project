#!/usr/bin/env python3
"""Turn a flat RISC-V binary (objcopy -O binary) into a $readmemh file.

One little-endian 32-bit word per line, starting at RAM word 0, padded with
zeros to the full RAM size, so the file loads straight into dual_port_ram
(rtl/soc_top.v FIRMWARE parameter) and unused RAM starts at 0, not X.
objcopy's own `-O verilog` output is not used: binutils 2.35 writes the words
byte-reversed and puts byte addresses after '@'.

    python3 scripts/bin2hex.py fw.bin fw.hex [--words 16384]
"""
import argparse
import sys
from pathlib import Path


def bin_to_words(data):
    data = data + bytes(-len(data) % 4)
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("binary", type=Path)
    parser.add_argument("hexfile", type=Path)
    parser.add_argument("--words", type=int, default=1 << 14,
                        help="RAM size in words; the image must fit (default 16384 = 64 KB)")
    args = parser.parse_args(argv)

    words = bin_to_words(args.binary.read_bytes())
    if len(words) > args.words:
        sys.exit(f"error: image is {4*len(words)} bytes, RAM holds {4*args.words}")
    used = len(words)
    words += [0] * (args.words - used)
    args.hexfile.parent.mkdir(parents=True, exist_ok=True)
    args.hexfile.write_text("".join(f"{w:08x}\n" for w in words))
    print(f"{args.hexfile}: {4*used} bytes of program in a {4*args.words}-byte image")


if __name__ == "__main__":
    main()
