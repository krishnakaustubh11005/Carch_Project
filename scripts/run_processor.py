#!/usr/bin/env python3
"""Build RV32IM firmware and run processor-driven accelerator integration."""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "golden"))
import model
from verify import sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrices', type=Path, default=ROOT / 'golden/accelerator_matrices.json')
    parser.add_argument('--riscv-prefix', default=os.environ.get('RISCV_PREFIX', 'riscv64-unknown-elf-'))
    parser.add_argument('--iverilog', default='iverilog')
    parser.add_argument('--vvp', default='vvp')
    parser.add_argument('--vcd', action='store_true')
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'sim/build/processor')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    (ROOT / 'sim/vcd').mkdir(parents=True, exist_ok=True)
    log = build / 'run.log'
    log.write_text('Processor + accelerator integration\n')

    def run(command):
        with log.open('a') as stream:
            stream.write('$ ' + shlex.join(map(str, command)) + '\n')
            stream.flush()
            result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
            stream.write(result.stdout)
        if result.returncode:
            raise RuntimeError(result.stdout or f'Command failed: {command[0]}')
        return result.stdout

    try:
        processor = ROOT / 'external/picorv32/picorv32.v'
        if not processor.is_file():
            raise ValueError('Missing external/picorv32/picorv32.v; initialize the PicoRV32 checkout first')
        cc, objcopy = args.riscv_prefix + 'gcc', args.riscv_prefix + 'objcopy'
        for executable in (cc, objcopy, args.iverilog, args.vvp):
            if not shutil.which(executable):
                raise ValueError(f'Missing required tool: {executable}')
        cases = model.write_array_vectors(args.matrices, build / 'vectors.txt', build / 'expected.json')
        if any(case['K'] != 4 for case in cases):
            raise ValueError('Processor integration requires 4x4 matrices (K=4)')
        header = ['#include <stdint.h>',
                  'struct test_case { int8_t a[16], b[16]; int32_t expected[16]; };',
                  f'#define CASE_COUNT {len(cases)}',
                  'static const struct test_case cases[] = {']
        for case in cases:
            fields = []
            for name in ('A', 'B', 'C'):
                fields.append('{' + ','.join(str(v) for row in case[name] for v in row) + '}')
            header.append('{' + ','.join(fields) + '},')
        header.append('};')
        (build / 'cases.h').write_text('\n'.join(header) + '\n')
        firmware = ROOT / 'sw/firmware'
        driver = ROOT / 'sw/accelerator'
        run([cc, '-march=rv32im', '-mabi=ilp32', '-O2', '-std=c11',
             '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-builtin',
             '-msmall-data-limit=0', '-nostdlib', '-I', build, '-I', driver,
             '-T', firmware / 'link.ld', firmware / 'start.S', firmware / 'main.c',
             driver / 'driver.c', '-lgcc', '-o', build / 'firmware.elf'])
        run([objcopy, '-O', 'binary', build / 'firmware.elf', build / 'firmware.bin'])
        binary = (build / 'firmware.bin').read_bytes()
        if len(binary) > 65536:
            raise ValueError('Firmware exceeds 64 KiB RAM')
        binary += bytes(65536 - len(binary))
        hex_file = build / 'firmware.hex'
        hex_file.write_text(''.join(f'{int.from_bytes(binary[i:i+4], "little"):08x}\n'
                                    for i in range(0, 65536, 4)))
        run([args.iverilog, '-g2001', '-s', 'system_picorv32_accelerator',
             '-o', build / 'system.vvp', ROOT / 'tb/system_picorv32_accelerator.v',
             ROOT / 'rtl/picorv32_accelerator.v', processor] + sources(ROOT, 'accelerator_mmio'))
        command = [args.vvp, build / 'system.vvp', f'+FIRMWARE={hex_file}', f'+CASES={len(cases)}']
        if args.vcd:
            command.append('+vcd')
        output = run(command)
        print(output, end='')
        if f'PROCESSOR PASS cases={len(cases)} checks={len(cases)*32}' not in output or 'TEST PASSED' not in output.splitlines():
            raise RuntimeError('Missing processor success marker')
        print(f'Full build/simulation log: {log}')
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        with log.open('a') as stream:
            stream.write(f'ERROR: {error}\n')
        parser.exit(1, f'ERROR: {error}\nSee {log}\n')


if __name__ == '__main__':
    main()
