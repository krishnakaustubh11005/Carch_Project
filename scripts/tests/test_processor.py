"""Real CPU/firmware integration, skipped when optional prerequisites are absent."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = os.environ.get('RISCV_PREFIX', 'riscv64-unknown-elf-')
AVAILABLE = (all(shutil.which(tool) for tool in
                 (PREFIX + 'gcc', PREFIX + 'objcopy', 'iverilog', 'vvp'))
             and (ROOT / 'external/picorv32/picorv32.v').is_file())


@unittest.skipUnless(AVAILABLE, 'PicoRV32 checkout, RISC-V toolchain, and Icarus required')
class ProcessorIntegrationTests(unittest.TestCase):
    def test_firmware_checks_cpu_and_accelerator_and_rejects_instruction_trap(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            result = subprocess.run(
                [sys.executable, str(ROOT / 'scripts/run_processor.py'), '--build-dir', directory],
                cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PROCESSOR PASS cases=8 checks=256', result.stdout)
            # Corrupt the entry instruction in the compiled image. A trapped
            # CPU must fail instead of producing a misleading success marker.
            words = (build / 'firmware.hex').read_text().splitlines()
            words[0] = 'ffffffff'
            bad_image = build / 'bad.hex'
            bad_image.write_text('\n'.join(words) + '\n')
            result = subprocess.run(
                ['vvp', str(build / 'system.vvp'), f'+FIRMWARE={bad_image}', '+CASES=8'],
                cwd=ROOT, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unexpected CPU trap', result.stdout)
            self.assertNotIn('TEST PASSED', result.stdout)
