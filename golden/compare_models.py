#!/usr/bin/env python3
"""
Compare the C and Python INT8 matrix-multiplication reference models.

Run from the repository root:
    python3 golden/compare_models.py

The script compiles matrix_multiply.c into a temporary shared library,
loads it with ctypes, and compares its results with model.py.
"""

import ctypes
import random
import subprocess
import tempfile
from pathlib import Path

from model import matrix_multiply


GOLDEN_DIR = Path(__file__).resolve().parent
C_SOURCE = GOLDEN_DIR / "matrix_multiply.c"


def build_c_library(output_path: Path) -> None:
    command = [
        "gcc",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-O2",
        "-fPIC",
        "-shared",
        "-DMATRIX_MULTIPLY_NO_MAIN",
        str(C_SOURCE),
        "-o",
        str(output_path),
    ]
    subprocess.run(command, check=True)


def load_c_library(library_path: Path):
    library = ctypes.CDLL(str(library_path))
    int8_pointer = ctypes.POINTER(ctypes.c_int8)
    int32_pointer = ctypes.POINTER(ctypes.c_int32)

    library.matrix_multiply_int8.argtypes = [
        int8_pointer,
        int8_pointer,
        int32_pointer,
        ctypes.c_size_t,
        ctypes.c_size_t,
        ctypes.c_size_t,
    ]
    library.matrix_multiply_int8.restype = ctypes.c_int
    return library


def compare_one_case(library, A, B, case_name: str) -> None:
    M = len(A)
    K = len(A[0])
    N = len(B[0])

    # Convert the row-major Python matrices into C-compatible arrays.
    A_values = [value for row in A for value in row]
    B_values = [value for row in B for value in row]

    A_c = (ctypes.c_int8 * len(A_values))(*A_values)
    B_c = (ctypes.c_int8 * len(B_values))(*B_values)
    C_c = (ctypes.c_int32 * (M * N))()

    status = library.matrix_multiply_int8(
        A_c, B_c, C_c, M, K, N
    )
    if status != 0:
        raise RuntimeError(f"{case_name}: C model returned status {status}")

    c_result = [
        list(C_c[row * N:(row + 1) * N])
        for row in range(M)
    ]

    python_result = matrix_multiply(
        A, B, data_w=8, k_max=256, acc_w=24
    )

    if python_result != c_result:
        print(f"FAIL: {case_name}")
        print("Python result:", python_result)
        print("C result:     ", c_result)
        raise AssertionError(f"C and Python results differ in {case_name}")

    print(f"PASS: {case_name} ({M}x{K} multiplied by {K}x{N})")


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        library_path = Path(temporary_directory) / "libmatrix_multiply.so"
        build_c_library(library_path)
        library = load_c_library(library_path)

        # Boundary length and signed operand extremes.
        compare_one_case(library, [[-128] * 256], [[-128]] * 256,
                         "maximum K and minimum INT8 operands")
        compare_one_case(library, [[-128, 127]], [[127], [-128]],
                         "mixed signed extremes")
        value = (ctypes.c_int8 * 1)(1)
        output = (ctypes.c_int32 * 1)()
        for a, b, c, m, k, n in [
            (None, value, output, 1, 1, 1),
            (value, None, output, 1, 1, 1),
            (value, value, None, 1, 1, 1),
            (value, value, output, 0, 1, 1),
            (value, value, output, 1, 0, 1),
            (value, value, output, 1, 1, 0),
            (value, value, output, 1, 257, 1),
        ]:
            if library.matrix_multiply_int8(a, b, c, m, k, n) != -1:
                raise AssertionError("Invalid arguments were not rejected")
        print("PASS: invalid pointers and dimensions rejected")

        # Small hand-checkable square matrix.
        compare_one_case(
            library,
            [[1, 2], [3, 4]],
            [[5, 6], [7, 8]],
            "2x2 example",
        )

        # Rectangular matrix case.
        compare_one_case(
            library,
            [[1, 2, 3], [4, 5, 6]],
            [[7, 8], [9, 10], [11, 12]],
            "rectangular example",
        )

        # Random signed INT8 matrices, including negative values.
        random_generator = random.Random(42)
        for test_number in range(1, 11):
            M, K, N = 3, 5, 4
            A = [
                [random_generator.randint(-128, 127) for _ in range(K)]
                for _ in range(M)
            ]
            B = [
                [random_generator.randint(-128, 127) for _ in range(N)]
                for _ in range(K)
            ]
            compare_one_case(
                library, A, B, f"random test {test_number}"
            )

    print("\nAll C and Python golden-model tests passed.")


if __name__ == "__main__":
    main()
