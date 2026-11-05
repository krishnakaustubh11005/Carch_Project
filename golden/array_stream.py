#!/usr/bin/env python3
"""Generate a reproducible matrix stream for the Python-golden RTL check."""

import argparse
import json
from pathlib import Path

from model import ROOT, array_stream


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--seed", type=int, default=20261105)
    parser.add_argument("--output", type=Path,
                        default=ROOT.parent / "sim/build/vectors/array_stream_matrices.json")
    args = parser.parse_args()
    try:
        document = array_stream(args.count, args.seed)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(document, indent=2) + "\n")
    except (ValueError, OSError) as error:
        parser.exit(2, f"ERROR: {error}\n")
    print(f"Generated {args.count} back-to-back 4x4 matmuls; seed={args.seed}")
    print(f"First {min(args.count, 8)} cases cover directed corners; remaining cases are random.")
    print(f"Matrix inputs: {args.output}")


if __name__ == "__main__":
    main()
