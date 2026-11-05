#!/usr/bin/env python3
"""Calculate matrix products and export inputs/expected values for RTL."""

import argparse
from pathlib import Path

from model import ROOT, write_array_vectors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrices", type=Path, default=ROOT / "array_matrices.json")
    parser.add_argument("--vectors", type=Path,
                        default=ROOT / "vectors/systolic_4_4_array.txt")
    parser.add_argument("--results", type=Path, default=ROOT / "expected/array_results.json")
    args = parser.parse_args()
    try:
        cases = write_array_vectors(args.matrices, args.vectors, args.results)
    except (ValueError, OSError) as error:
        parser.exit(2, f"ERROR: {error}\n")
    for index, case in enumerate(cases, 1):
        print(f"Matmul {index}: Python golden C = A x B")
        for row in case["C"]:
            print("  " + " ".join(f"{value:6d}" for value in row))
    print(f"Inputs and expected values: {args.vectors}")
    print(f"Matrices and golden results: {args.results}")


if __name__ == "__main__":
    main()
