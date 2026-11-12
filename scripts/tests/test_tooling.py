"""Tests of verification infrastructure, not substitute hardware implementations."""

import argparse
import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import verify

model = verify.model


class ArithmeticTests(unittest.TestCase):
    def test_array_python_export_known_products_and_signed_hex(self):
        with tempfile.TemporaryDirectory() as directory:
            vectors = Path(directory) / "array.txt"
            report = Path(directory) / "results.json"
            cases = model.write_array_vectors(ROOT / "golden/array_matrices.json", vectors, report)
            self.assertEqual(cases[0]["C"], [[27, 11, 4, 1], [67, 27, 16, 9],
                                           [107, 43, 28, 17], [147, 59, 40, 25]])
            self.assertEqual(cases[1]["C"], [[12, 9, -10, -3], [3, -10, 17, 5],
                                           [22, -4, -1, -15], [-21, 4, 8, 22]])
            records = vectors.read_text().splitlines()
            self.assertEqual(len(records), 66)
            self.assertEqual(records[0], "4")
            self.assertEqual(records[34], "ff 02")
            self.assertEqual(records[52], "fffff6")
            self.assertEqual(json.loads(report.read_text())["cases"], cases)

    def test_array_python_export_rejects_invalid_matrices(self):
        original = json.loads((ROOT / "golden/array_matrices.json").read_text())
        invalid = [{"cases": []}, {"cases": "invalid"}]
        for bad_value in (128, -129, 1.5, True):
            case = json.loads(json.dumps(original))
            case["cases"][0]["A"][0][0] = bad_value
            invalid.append(case)
        case = json.loads(json.dumps(original))
        case["cases"][1]["B"][0].pop()
        invalid.append(case)
        for inner in (0, 257):
            invalid.append({"cases": [{"A": [[0]*inner for _ in range(4)],
                                       "B": [[0]*4 for _ in range(inner)]}]})
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "matrices.json"
            for document in invalid:
                with self.subTest(document=document):
                    source.write_text(json.dumps(document))
                    with self.assertRaises(ValueError):
                        model.write_array_vectors(source, Path(directory) / "array.txt")

    def test_array_python_export_int8_extremes(self):
        cases = {"cases": [{"A": [[-128]*4 for _ in range(4)],
                            "B": [[value]*4 for _ in range(4)]}
                           for value in (-128, 127)]}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "matrices.json"
            source.write_text(json.dumps(cases))
            results = model.write_array_vectors(source, Path(directory) / "array.txt")
            self.assertEqual(results[0]["C"], [[65536]*4 for _ in range(4)])
            self.assertEqual(results[1]["C"], [[-65024]*4 for _ in range(4)])

    def test_array_stream_is_reproducible_and_exports_all_cases(self):
        stream = model.array_stream(20, 123)
        self.assertEqual(stream, model.array_stream(20, 123))
        self.assertNotEqual(stream, model.array_stream(20, 124))
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "stream.json"
            vectors = Path(directory) / "stream.txt"
            source.write_text(json.dumps(stream))
            results = model.write_array_vectors(source, vectors)
            self.assertEqual(len(results), 20)
            self.assertEqual(len(vectors.read_text().splitlines()), 20*33)
            self.assertEqual(results[0]["C"], [[0]*4 for _ in range(4)])
            self.assertEqual(results[1]["C"], results[1]["B"])
            self.assertEqual(results[2]["C"], results[2]["A"])
            self.assertEqual(results[3]["C"], [[65536]*4 for _ in range(4)])
            self.assertEqual(results[4]["C"], [[-65024]*4 for _ in range(4)])
        for bad_count in (0, -1, True):
            with self.assertRaises(ValueError):
                model.array_stream(bad_count)

    def test_array_sizes_export_shapes_and_maximum_k(self):
        document = model.array_sizes(123)
        self.assertEqual(document, model.array_sizes(123))
        sizes = [len(case["B"]) for case in document["cases"]]
        self.assertEqual(sizes, [1, 1, 2, 3, 4, 5, 7, 8, 16, 31, 64, 128, 256, 1, 1])
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sizes.json"
            vectors = Path(directory) / "sizes.txt"
            source.write_text(json.dumps(document))
            results = model.write_array_vectors(source, vectors)
            self.assertTrue(all(len(case["C"]) == 4 and len(case["C"][0]) == 4
                                for case in results))
            self.assertEqual(results[12]["C"], [[4194304]*4 for _ in range(4)])
            self.assertEqual(len(vectors.read_text().splitlines()), sum(1+4*k+16 for k in sizes))

    def test_signed_extremes_and_wrap(self):
        self.assertEqual(model.signed(128, 8), -128)
        self.assertEqual(model.signed(255, 8), -1)
        self.assertEqual(model.signed(-129, 8), 127)
        self.assertEqual(model.mac(0, -128, -128, 8, 24), 16384)
        self.assertEqual(model.mac(16384, -128, -128, 8, 16), -32768)

    def test_accumulator_bound(self):
        self.assertEqual(model.minimum_acc_width(8, 256), 24)
        self.assertEqual(model.minimum_acc_width(16, 256), 40)
        self.assertEqual(model.minimum_acc_width(4, 1), 8)
        self.assertEqual(model.minimum_acc_width(4, 3), 10)
        for args in ((1, 256, 24), (8, 0, 24), (8, 256, 23)):
            with self.assertRaises(ValueError):
                model.validate_config(*args)

    def test_rectangular_matrix_and_signed_inputs(self):
        self.assertEqual(model.matrix_multiply([[1, 2, 3]], [[1, 2], [3, 4], [5, 6]]), [[22, 28]])
        self.assertEqual(model.matrix_multiply([[255, 128]], [[1], [1]]), [[-129]])
        self.assertEqual(model.matrix_multiply([[-128] * 256], [[-128]] * 256), [[4194304]])

    def test_invalid_matrix_shapes_and_operation_length(self):
        for a, b, k in (([], [[1]], 256), ([[1, 2]], [[1]], 256),
                        ([[1], [1, 2]], [[1]], 256), ([[1, 2]], [[1], [2]], 1)):
            with self.assertRaises(ValueError):
                model.matrix_multiply(a, b, k_max=k)

    def test_wide_arithmetic_uses_python_integers(self):
        width, count = 40, 3
        minimum = -(1 << (width - 1))
        expected = count * minimum * minimum
        self.assertEqual(model.matrix_multiply([[minimum] * count], [[minimum]] * count,
                                              data_w=width, k_max=count), [[expected]])

    def test_pe_priority_stalls_and_independent_streams(self):
        state = (7, 2, -3, 1, 1)
        self.assertEqual(model.pe_step(state, (1, 1, 1, 1, 1, 2, 3), 8, 24), (0, 0, 0, 0, 0))
        self.assertEqual(model.pe_step(state, (0, 1, 0, 1, 1, 2, 3), 8, 24), (0, 0, 0, 0, 0))
        self.assertEqual(model.pe_step(state, (0, 0, 0, 1, 1, 4, 5), 8, 24), state)
        self.assertEqual(model.pe_step(state, (0, 0, 1, 1, 0, 4, 5), 8, 24), (7, 4, 5, 1, 0))
        self.assertEqual(model.pe_step(state, (0, 0, 1, 0, 1, 4, 5), 8, 24), (7, 4, 5, 0, 1))
        self.assertEqual(model.pe_step(state, (0, 0, 1, 1, 1, -4, 5), 8, 24), (-13, -4, 5, 1, 1))

    def test_vectors_deterministic_and_exhaustive(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / "a", Path(directory) / "b"
            self.assertEqual(model.write_vectors("signed_multiplier", 4, a), 256)
            model.write_vectors("signed_multiplier", 4, b)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            lines = [tuple(int(x, 16) for x in row.split()) for row in a.read_text().splitlines()]
            self.assertIn((13, 3, 247), lines)  # -3 * 3 = -9
            self.assertIn((8, 8, 64), lines)    # minimum * minimum
            self.assertEqual(model.write_vectors("signed_multiplier", 8, a), 65536)
            model.write_vectors("signed_multiplier", 8, b)
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_shifted_carry_contract_and_width_one(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "csa"
            self.assertEqual(model.write_vectors("carry_save_adder", 1, path), 8)
            for row in path.read_text().splitlines():
                a, b, c, total, carry = (int(value, 16) for value in row.split())
                self.assertEqual((total + carry) & 1, (a + b + c) & 1)
                self.assertEqual(carry, 0)

    def test_pe_vectors_never_exceed_k_max(self):
        count = 0
        for row in model.pe_vectors(4, 1, 8):
            rst, clear, en, av, bv = row[:5]
            if rst or clear:
                count = 0
            elif en and av and bv:
                count += 1
            self.assertLessEqual(count, 1)

    def test_booth_pp_minimum_operand_corners_and_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pp.txt"
            self.assertEqual(model.write_vectors("booth_pp_gen", 8, path), 1536)
            rows = {tuple(int(value, 16) for value in row.split())
                    for row in path.read_text().splitlines()}
            self.assertIn((128, 0, 0, 1, 256, 0), rows)  # +2 * -128 = -256
            self.assertIn((128, 1, 0, 1, 767, 1), rows)  # -2 * -128 = +256
            self.assertIn((127, 1, 0, 1, 257, 1), rows)  # -2 * +127 = -254
            self.assertIn((0, 0, 0, 0, 512, 0), rows)
            self.assertIn((0, 1, 0, 0, 511, 1), rows)    # negative zero is harmless

    def test_booth_pp_bias_identity_and_determinism(self):
        with tempfile.TemporaryDirectory() as directory:
            path, repeat = Path(directory) / "pp", Path(directory) / "repeat"
            for width in (2, 3, 4, 8, 16):
                count = model.write_vectors("booth_pp_gen", width, path)
                self.assertEqual(count, 6 * (1 << width) if width <= 8 else 6036)
                model.write_vectors("booth_pp_gen", width, repeat)
                self.assertEqual(path.read_bytes(), repeat.read_bytes())
                for row in path.read_text().splitlines():
                    x, sign, one, two, pp, neg = (int(value, 16) for value in row.split())
                    digit = -(one + 2*two) if sign else one + 2*two
                    self.assertEqual(pp + neg - (1 << (width + 1)),
                                     model.signed(x, width) * digit)
                    self.assertTrue(0 <= pp < (1 << (width + 2)))
                    self.assertEqual(neg, sign)

    def test_compressor_vectors_exhaustive_and_modular(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tree"
            self.assertEqual(model.write_vectors("compressor_tree", 2, path, rows=3), 64)
            vectors = {tuple(int(field, 16) for field in line.split())
                       for line in path.read_text().splitlines()}
            self.assertIn((63, 1), vectors)  # three values of 3 wrap to 1 at width two
            self.assertIn((0, 0), vectors)
            self.assertEqual(len(vectors), 64)
            with self.assertRaises(ValueError):
                model.write_vectors("compressor_tree", 2, path, rows=0)

    def test_mac_vectors_sign_extension_and_accumulator_wrap(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mac"
            self.assertEqual(model.write_vectors("booth_mac_datapath", 8, path), 1168)
            vectors = {tuple(int(field, 16) for field in line.split())
                       for line in path.read_text().splitlines()}
            self.assertIn((128, 127, 0, 0, 0xFFC080), vectors)
            self.assertIn((128, 128, 0, 0, 16384), vectors)
            self.assertIn((128, 127, 0xFFFFFF, 1, 0xFFC080), vectors)
            self.assertIn((0, 0, 0xFFFFFF, 0xFFFFFF, 0xFFFFFE), vectors)

    def test_clocked_pe_drain_priority_result_hold_and_valid_pulse(self):
        state = model.ClockedPEState(accumulator=42, a_out=3, b_out=-4,
                                    a_valid_out=1, b_valid_out=0, result=5)
        drained = model.clocked_pe_step(state, (0, 0, 1, 1, 1, 1, 127, 127), 8, 24)
        self.assertEqual(drained, model.ClockedPEState(16129, 127, 127, 1, 1, 42, 1))
        repeated = model.clocked_pe_step(drained, (0, 0, 1, 0, 1, 1, 127, 127), 8, 24)
        self.assertEqual(repeated, model.ClockedPEState(0, 127, 127, 1, 1, 16129, 1))
        stalled = model.clocked_pe_step(drained, (0, 0, 0, 0, 1, 1, 127, 127), 8, 24)
        self.assertEqual(stalled, model.ClockedPEState(16129, 127, 127, 1, 1, 42, 0))
        continued = model.clocked_pe_step(stalled, (0, 0, 0, 1, 1, 1, 2, 3), 8, 24)
        self.assertEqual(continued, model.ClockedPEState(16135, 2, 3, 1, 1, 42, 0))
        for signals in ((0, 1, 1, 1, 1, 1, 127, 127), (1, 1, 1, 1, 1, 1, 127, 127)):
            self.assertEqual(model.clocked_pe_step(continued, signals, 8, 24), model.ClockedPEState())

    def test_clocked_pe_drain_enable_valid_truth_table(self):
        state = model.ClockedPEState(42, 3, -4, 1, 0, 5, 1)
        for drain in (0, 1):
            for en in (0, 1):
                for av in (0, 1):
                    for bv in (0, 1):
                        with self.subTest(drain=drain, en=en, av=av, bv=bv):
                            observed = model.clocked_pe_step(
                                state, (0, 0, drain, en, av, bv, -2, 3), 8, 24)
                            base = 0 if drain else 42
                            self.assertEqual(observed, model.ClockedPEState(
                                base - 6 if en and av and bv else base,
                                -2 if en else 3, 3 if en else -4,
                                av if en else 1, bv if en else 0,
                                42 if drain else 5, drain))

    def test_clocked_pe_continuous_tiles_have_no_lost_boundary_product(self):
        state = model.ClockedPEState()
        # Two two-product tiles: 2*3 + (-4)*5 = -14; (-2)*7 + 3*4 = -2.
        for signals in ((0, 0, 0, 1, 1, 1, 2, 3),
                        (0, 0, 0, 1, 1, 1, -4, 5)):
            state = model.clocked_pe_step(state, signals, 8, 24)
        state = model.clocked_pe_step(state, (0, 0, 1, 1, 1, 1, -2, 7), 8, 24)
        self.assertEqual((state.result, state.result_valid, state.accumulator), (-14, 1, -14))
        state = model.clocked_pe_step(state, (0, 0, 0, 1, 1, 1, 3, 4), 8, 24)
        self.assertEqual((state.result, state.result_valid, state.accumulator), (-14, 0, -2))
        state = model.clocked_pe_step(state, (0, 0, 1, 0, 0, 0, 0, 0), 8, 24)
        self.assertEqual((state.result, state.result_valid, state.accumulator), (-2, 1, 0))

    def test_clocked_pe_fixed_point_example(self):
        state = model.ClockedPEState()
        state = model.clocked_pe_step(state, (0, 0, 0, 1, 1, 1, 24, -32), 8, 24)
        state = model.clocked_pe_step(state, (0, 0, 0, 1, 1, 1, 8, 16), 8, 24)
        state = model.clocked_pe_step(state, (0, 0, 1, 0, 0, 0, 0, 0), 8, 24)
        self.assertEqual(state.result, -640)  # F=4: -640 / 2^8 = -2.5
        self.assertEqual(state.result_valid, 1)

    def test_clocked_pe_vectors_obey_operation_length_and_cover_drain(self):
        for k_max in (1, 3, 16):
            accepted, maximum, drains = 0, 0, 0
            for signals, state in model.clocked_pe_vectors(8, k_max, model.minimum_acc_width(8, k_max)):
                rst, clear, drain, en, av, bv = signals[:6]
                if rst or clear:
                    accepted = 0
                elif drain:
                    drains += 1
                    accepted = 0
                    if not (en and av and bv):
                        self.assertEqual(state.accumulator, 0)
                if not rst and not clear and en and av and bv:
                    accepted += 1
                maximum = max(maximum, accepted)
                self.assertLessEqual(accepted, k_max)
                self.assertEqual(state.result_valid, int(bool(drain and not rst and not clear)))
            self.assertEqual(maximum, k_max)
            self.assertGreater(drains, 10)



class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("rtl", "tb"):
            (self.root / name).mkdir()
        self.options = argparse.Namespace(module=None, widths="", k_max=256, acc_w=None,
            rows=7, timeout=1, strict=False, iverilog="iverilog", vvp="vvp")

    def run_test(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return verify.test(self.root, self.options)

    def placeholder(self, name, rtl=False):
        # Files only exercise discovery; mocked compiler/simulator do not execute RTL.
        (self.root / "tb" / f"tb_{name}.v").write_text("// test fixture\n")
        if rtl:
            (self.root / "rtl" / f"{name}.v").write_text("// test fixture\n")

    def test_pending_is_not_pass_and_strict_fails(self):
        self.placeholder("half_adder")
        self.assertEqual(self.run_test(), 0)
        report = json.loads((self.root / "sim/build/report.json").read_text())
        self.assertEqual(report[0]["status"], "PENDING")
        self.options.strict = True
        self.assertEqual(self.run_test(), 1)
        self.options.strict = False
        self.options.module = "half_adder"
        self.assertEqual(self.run_test(), 1)

    def test_empty_strict_suite_fails(self):
        self.options.strict = True
        self.assertEqual(self.run_test(), 1)

    def test_dependency_closure_excludes_unrelated_pe(self):
        names = [path.name for path in verify.sources(self.root, "signed_multiplier")]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("half_adder.v", names)
        self.assertIn("compressor_tree.v", names)
        self.assertIn("booth_pp_gen.v", names)
        self.assertNotIn("carry_save_adder.v", names)
        self.assertNotIn("pe.v", names)
        self.assertEqual([path.name for path in verify.sources(self.root, "half_adder")], ["half_adder.v"])

    def test_success_requires_exact_marker_and_zero_exit(self):
        self.assertTrue(verify.passed(0, "Checks: 4\nTEST PASSED\n"))
        for code, output in ((1, "TEST PASSED"), (0, ""), (0, "mentions TEST PASSED here"),
                             (0, "TEST FAILED\nTEST PASSED")):
            self.assertFalse(verify.passed(code, output))

    def test_compile_failure_stops_simulation(self):
        self.placeholder("half_adder", rtl=True)
        with mock.patch.object(verify, "execute", return_value=(2, "syntax error")) as execute:
            self.assertEqual(self.run_test(), 1)
            self.assertEqual(execute.call_count, 1)

    def test_suite_continues_after_failure(self):
        self.placeholder("half_adder", rtl=True)
        self.placeholder("full_adder", rtl=True)
        with mock.patch.object(verify, "execute", side_effect=[
                (0, ""), (0, "TEST FAILED"), (0, ""), (0, "TEST PASSED")]):
            self.assertEqual(self.run_test(), 1)
        report = json.loads((self.root / "sim/build/report.json").read_text())
        self.assertEqual([row["status"] for row in report], ["FAIL", "PASS"])

    def test_missing_success_marker_fails(self):
        self.placeholder("half_adder", rtl=True)
        with mock.patch.object(verify, "execute", side_effect=[(0, ""), (0, "finished")]):
            self.assertEqual(self.run_test(), 1)

    def test_pass_creates_log_and_uses_explicit_top(self):
        self.placeholder("half_adder", rtl=True)
        with mock.patch.object(verify, "execute", side_effect=[(0, ""), (0, "TEST PASSED")]) as execute:
            self.assertEqual(self.run_test(), 0)
            command = execute.call_args_list[0].args[0]
            self.assertEqual(command[command.index("-s") + 1], "tb_half_adder")
            self.assertNotIn(str(self.root / "rtl/pe.v"), command)
        self.assertIn("TEST PASSED", (self.root / "sim/build/logs/half_adder.log").read_text())

    def test_invalid_configuration_rejected_before_compilation(self):
        self.placeholder("pe")
        self.options.module, self.options.widths, self.options.acc_w = "pe", "8", 16
        with mock.patch.object(verify, "execute") as execute:
            with self.assertRaises(ValueError):
                self.run_test()
            execute.assert_not_called()

    def test_unknown_module_is_discovered(self):
        self.placeholder("example")
        self.assertEqual(verify.discover(self.root), ["example"])

    def test_pe_alias_selects_clocked_booth_and_excludes_old_template(self):
        self.placeholder("pe")
        self.placeholder("pe_booth_csa")
        self.assertEqual(verify.discover(self.root), ["pe_booth_csa"])
        self.options.module = "pe"
        self.assertEqual(self.run_test(), 1)  # missing RTL, but the alias is resolved
        report = json.loads((self.root / "sim/build/report.json").read_text())
        self.assertEqual(report[0]["module"], "pe_booth_csa")

    def test_pp_generator_invalid_width_rejected_before_compilation(self):
        self.placeholder("booth_pp_gen", rtl=True)
        self.options.module, self.options.widths = "booth_pp_gen", "1"
        with mock.patch.object(verify, "execute") as execute:
            with self.assertRaisesRegex(ValueError, "DATA_W must be >= 2"):
                self.run_test()
            execute.assert_not_called()

    def test_zero_tree_rows_rejected_before_compilation(self):
        self.placeholder("compressor_tree", rtl=True)
        self.options.module, self.options.rows = "compressor_tree", 0
        with mock.patch.object(verify, "execute") as execute:
            with self.assertRaisesRegex(ValueError, "ROWS"):
                self.run_test()
            execute.assert_not_called()

    def test_real_process_timeout_and_missing_tool(self):
        code, text = verify.execute([sys.executable, "-c", "import time; time.sleep(1)"], self.root, 0.02)
        self.assertEqual(code, 124)
        self.assertIn("TIMEOUT", text)
        code, _ = verify.execute([str(self.root / "nonexistent")], self.root, 1)
        self.assertEqual(code, 127)

    def test_verilator_missing_is_skip(self):
        options = argparse.Namespace(verilator="missing-verilator", timeout=1)
        stream = io.StringIO()
        with mock.patch.object(verify.shutil, "which", return_value=None), contextlib.redirect_stdout(stream):
            self.assertEqual(verify.lint(self.root, options), 0)
        self.assertIn("SKIP", stream.getvalue())
        self.assertNotIn("PASS", stream.getvalue())


@unittest.skipUnless(shutil.which("iverilog"), "Icarus Verilog not installed")
class TestbenchSyntaxTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("vvp"), "vvp not installed")
    def test_structural_tree_row_boundaries_with_real_adders(self):
        # Exercise recursion bases and all remainder paths independently of Booth.
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "sim/vcd").mkdir(parents=True)
            for rows in (1, 2, 3, 4, 5, 6, 7, 8, 11):
                with self.subTest(rows=rows):
                    vectors, binary = directory / "vectors", directory / "tree.vvp"
                    count = model.write_vectors("compressor_tree", 3, vectors, rows=rows)
                    result = subprocess.run(["iverilog", "-g2001", "-I", str(ROOT / "tb"),
                        "-s", "tb_compressor_tree", "-Ptb_compressor_tree.WIDTH=3",
                        f"-Ptb_compressor_tree.ROWS={rows}", "-o", str(binary),
                        str(ROOT / "tb/tb_compressor_tree.v"), str(ROOT / "rtl/compressor_tree.v"),
                        str(ROOT / "rtl/full_adder.v"), str(ROOT / "rtl/half_adder.v")],
                        text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    result = subprocess.run(["vvp", str(binary), f"+VECTOR_FILE={vectors}"],
                        cwd=directory, text=True, capture_output=True, timeout=10)
                    self.assertTrue(verify.passed(result.returncode, result.stdout), result.stdout + result.stderr)
                    self.assertIn(f"Checks: {count}, errors: 0", result.stdout)
    def test_all_testbenches_parse_with_missing_duts_ignored(self):
        # -i suppresses missing DUT errors for syntax checking only. No hardware is supplied.
        with tempfile.TemporaryDirectory() as directory:
            for source in sorted((ROOT / "tb").glob("tb_*.v")):
                with self.subTest(testbench=source.name):
                    sources = [str(source)]
                    if source.stem == "tb_pe_booth_csa":
                        # The scoreboard inspects S/C registers. Include the PE,
                        # but ignore its missing MAC child for this harness check.
                        sources.append(str(ROOT / "rtl/pe_booth_csa.v"))
                    result = subprocess.run(["iverilog", "-g2001", "-i", "-I", str(ROOT / "tb"),
                        "-s", source.stem, "-o", str(Path(directory) / "syntax.vvp")] + sources,
                        text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def simulate_without_dut(self, source, directory, vector_mode="normal"):
        directory = Path(directory)
        (directory / "sim/vcd").mkdir(parents=True, exist_ok=True)
        name = source.stem[3:]
        binary = directory / "missing_dut.vvp"
        command = ["iverilog", "-g2001", "-i", "-I", str(ROOT / "tb"),
                   "-s", source.stem, "-o", str(binary)]
        arguments, count = [], {"half_adder": 4, "full_adder": 8,
                                "booth_recoder": 1288,
                                "systolic_4_4_array": 0,
                                "accelerator_4x4": 0,
                                "accelerator_mmio": 0}.get(name, 8)
        if name in ("systolic_4_4_array", "accelerator_4x4", "accelerator_mmio"):
            vectors = directory / "array.txt"
            model.write_array_vectors(ROOT / "golden/array_matrices.json", vectors)
            arguments.append(f"+VECTOR_FILE={vectors}")
        if name in verify.DEFAULT_WIDTHS:
            parameter = "DATA_W" if name in ("booth_pp_gen", "booth_mac_datapath", "signed_multiplier", "pe", "pe_booth_csa") else "WIDTH"
            command += [f"-P{source.stem}.{parameter}=2"]
            vectors = directory / "vectors.txt"
            count = model.write_vectors(name, 2, vectors)
            if vector_mode == "empty":
                vectors.write_text("")
                count = 0
            elif vector_mode == "malformed":
                vectors.write_text("1\n")
                count = 0
            arguments.append(f"+VECTOR_FILE={vectors}")
        sources = [str(source)]
        if name == "pe_booth_csa":
            # An absent MAC child leaves the PE's next S/C undriven, which must fail.
            sources.append(str(ROOT / "rtl/pe_booth_csa.v"))
        result = subprocess.run(command + sources, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = subprocess.run(["vvp", str(binary)] + arguments, cwd=directory,
                                capture_output=True, text=True, timeout=10)
        if name in ("booth_recoder", "booth_pp_gen", "compressor_tree", "booth_mac_datapath", "signed_multiplier", "pe_booth_csa", "systolic_4_4_array", "accelerator_4x4", "accelerator_mmio"):
            # This newer testbench also fails the simulator process itself.
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("TEST FAILED", result.stdout)
        self.assertNotIn("TEST PASSED", result.stdout)
        self.assertIn(f"Checks: {count},", result.stdout)
        return result.stdout

    @unittest.skipUnless(shutil.which("vvp"), "vvp not installed")
    def test_real_simulator_reads_all_vectors_and_detects_missing_duts(self):
        # Undriven outputs must fail, while every stimulus record is still processed.
        with tempfile.TemporaryDirectory() as directory:
            for source in sorted((ROOT / "tb").glob("tb_*.v")):
                with self.subTest(testbench=source.name):
                    self.simulate_without_dut(source, directory)

    @unittest.skipUnless(shutil.which("vvp"), "vvp not installed")
    def test_empty_and_malformed_vectors_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            for module in ("signed_multiplier", "booth_pp_gen", "pe_booth_csa"):
                for mode in ("empty", "malformed"):
                    with self.subTest(module=module, mode=mode):
                        output = self.simulate_without_dut(ROOT / f"tb/tb_{module}.v", directory, mode)
                        self.assertIn("no test cases executed", output)

    @unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "simulator not installed")
    def test_array_checks_python_vectors_and_rejects_bad_files(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "sim/vcd").mkdir(parents=True)
            binary = directory / "array.vvp"
            command = ["iverilog", "-g2001", "-s", "tb_systolic_4_4_array",
                       "-o", str(binary), str(ROOT / "tb/tb_systolic_4_4_array.v")]
            command += [str(path) for path in verify.sources(ROOT, "systolic_4_4_array")]
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            vectors = directory / "array.txt"
            model.write_array_vectors(ROOT / "golden/array_matrices.json", vectors)
            original = vectors.read_text()
            for mode in ("valid", "corrupt_expected", "empty", "truncated", "extra", "unknown", "zero_k", "oversize_k", "missing"):
                with self.subTest(mode=mode):
                    content = original
                    if mode == "corrupt_expected":
                        content = original.replace("00001b", "00001a", 1)
                    elif mode == "empty":
                        content = ""
                    elif mode == "truncated":
                        content = "\n".join(original.splitlines()[:-1]) + "\n"
                    elif mode == "extra":
                        content += "00 00 000000\n"
                    elif mode == "unknown":
                        lines = original.splitlines()
                        lines[1] = "xx 00"
                        content = "\n".join(lines) + "\n"
                    elif mode in ("zero_k", "oversize_k"):
                        lines = original.splitlines()
                        lines[0] = "0" if mode == "zero_k" else "257"
                        content = "\n".join(lines) + "\n"
                    vectors.write_text(content)
                    selected_path = directory / "absent.txt" if mode == "missing" else vectors
                    result = subprocess.run(["vvp", str(binary), f"+VECTOR_FILE={selected_path}"],
                                            cwd=directory, capture_output=True, text=True, timeout=10)
                    if mode == "valid":
                        self.assertTrue(verify.passed(result.returncode, result.stdout), result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn("TEST FAILED", result.stdout)
                        self.assertNotIn("TEST PASSED", result.stdout)


if __name__ == "__main__":
    unittest.main()
