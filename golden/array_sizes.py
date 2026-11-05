#!/usr/bin/env python3
"""Generate back-to-back 4xK times Kx4 tests with different K values."""

import argparse
import json
from pathlib import Path

from model import ROOT, array_sizes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=20261105)
    parser.add_argument("--output", type=Path,
                        default=ROOT.parent / "sim/build/vectors/array_sizes_matrices.json")
    args = parser.parse_args()
    document = array_sizes(args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n")
    sizes = [len(case["B"]) for case in document["cases"]]
    print(f"Mixed-size tests: A=4xK, B=Kx4, C=4x4; seed={args.seed}")
    print(f"K sequence: {sizes}")
    print(f"Matrix inputs: {args.output}")


if __name__ == "__main__":
    main()
