#!/usr/bin/env python3
"""Run the C golden model on the PicoRV32 submodule, without an accelerator."""
import os
from pathlib import Path
import random
import subprocess

from model import matrix_multiply

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "sim/build/cpu"
CPU = ROOT / "golden/cpu"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, timeout=120)


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    rng = random.Random(42)
    tests = [
        ([[1, 2], [3, 4]], [[5, 6], [7, 8]]),
        ([[1, -2, 3], [-4, 5, -6]], [[7, -8], [9, 10], [-11, 12]]),
        ([[-128] * 256], [[-128]] * 256),
    ]
    for m, k, n in [(3, 5, 4), (8, 8, 8)]:
        tests.append(([[rng.randint(-128, 127) for _ in range(k)] for _ in range(m)],
                      [[rng.randint(-128, 127) for _ in range(n)] for _ in range(k)]))
    declarations = ['#include <stdint.h>',
                    'struct test_case { const int8_t *a, *b; const int32_t *expected; unsigned m, k, n; };']
    entries = []
    for i, (a, b) in enumerate(tests):
        expected = matrix_multiply(a, b)
        for name, ctype, matrix in [('a', 'int8_t', a), ('b', 'int8_t', b),
                                    ('expected', 'int32_t', expected)]:
            values = ','.join(str(v) for row in matrix for v in row)
            declarations.append(f'static const {ctype} {name}{i}[] = {{{values}}};')
        m, k, n = len(a), len(b), len(b[0])
        entries.append(f'{{a{i}, b{i}, expected{i}, {m}, {k}, {n}}}')
        print(f'CASE {i}: {m}x{k} * {k}x{n}', flush=True)
    declarations += [f'#define CASE_COUNT {len(tests)}',
                     'static const struct test_case cases[] = {' + ','.join(entries) + '};',
                     f'static int32_t output[{max(len(a) * len(b[0]) for a, b in tests)}];']
    (BUILD / 'cases.h').write_text('\n'.join(declarations) + '\n')
    prefix = os.environ.get('RISCV_PREFIX', 'riscv64-unknown-elf-')
    run(prefix + 'gcc', '-march=rv32im', '-mabi=ilp32', '-O2', '-std=c11',
        '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-builtin',
        '-msmall-data-limit=0', '-nostdlib', '-DMATRIX_MULTIPLY_NO_MAIN',
        '-I', ROOT / 'golden', '-I', BUILD, '-T', CPU / 'link.ld',
        CPU / 'start.S', CPU / 'main.c', ROOT / 'golden/matrix_multiply.c',
        '-lgcc', '-o', BUILD / 'firmware.elf')
    run(prefix + 'objcopy', '-O', 'binary', BUILD / 'firmware.elf', BUILD / 'firmware.bin')
    binary = (BUILD / 'firmware.bin').read_bytes()
    if len(binary) > 65536:
        raise RuntimeError('Firmware exceeds simulated RAM capacity')
    binary += bytes(65536 - len(binary))
    (BUILD / 'firmware.hex').write_text(''.join(
        f'{int.from_bytes(binary[i:i+4], "little"):08x}\n' for i in range(0, 65536, 4)))
    run('iverilog', '-g2012', '-s', 'testbench', '-o', BUILD / 'cpu.vvp',
        CPU / 'testbench.v', ROOT / 'external/picorv32/picorv32.v')
    result = subprocess.run(['vvp', str(BUILD / 'cpu.vvp'),
                             f'+firmware={BUILD / "firmware.hex"}'],
                            cwd=ROOT, check=True, text=True, capture_output=True, timeout=120)
    print(result.stdout, end='')
    if f'CPU PASS cases={len(tests)}' not in result.stdout:
        raise RuntimeError('Simulation did not complete all cases')


if __name__ == '__main__':
    main()
