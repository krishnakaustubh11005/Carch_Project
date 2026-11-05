#!/usr/bin/env python3
"""Exact, dependency-free reference arithmetic and deterministic test vectors."""

import json
import random
from dataclasses import dataclass, replace
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SEED = 20261008
WIDTHS = (2, 3, 4, 8, 16)


def signed(value, width):
    if width < 1:
        raise ValueError("width must be positive")
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value


def minimum_acc_width(data_w, k_max):
    if data_w < 2 or k_max < 1:
        raise ValueError("DATA_W must be >= 2 and K_MAX must be >= 1")
    return 2 * data_w + (k_max - 1).bit_length()


def validate_config(data_w, k_max, acc_w):
    required = minimum_acc_width(data_w, k_max)
    if acc_w < required:
        raise ValueError(f"ACC_W={acc_w} is below the agreed bound {required}")


def mac(acc, a, b, data_w, acc_w):
    return signed(acc + signed(a, data_w) * signed(b, data_w), acc_w)


def matrix_multiply(a, b, data_w=8, k_max=256, acc_w=None):
    acc_w = minimum_acc_width(data_w, k_max) if acc_w is None else acc_w
    validate_config(data_w, k_max, acc_w)
    if not a or not b or not a[0] or not b[0]:
        raise ValueError("matrices must be nonempty")
    inner, cols = len(a[0]), len(b[0])
    if len(b) != inner or inner > k_max:
        raise ValueError("incompatible dimensions or inner dimension exceeds K_MAX")
    if any(len(row) != inner for row in a) or any(len(row) != cols for row in b):
        raise ValueError("ragged matrices are not supported")
    result = []
    for row in a:
        output = []
        for col in range(cols):
            acc = 0
            for k in range(inner):
                acc = mac(acc, row[k], b[k][col], data_w, acc_w)
            output.append(acc)
        result.append(output)
    return result


def golden_model_int8_matrix_multiply(a, b):
    """Compatibility name; returns plain Python integer lists, not NumPy arrays."""
    return matrix_multiply(a, b)


def write_array_vectors(matrices_path, vectors_path, results_path=None):
    """Export 4xK times Kx4 cases, each producing a 4x4 result.

    Per case: decimal K, then 4*K row-major A/B byte pairs in hexadecimal,
    then 16 row-major signed 24-bit expected C values in hexadecimal.
    Python arithmetic is independent of RTL state and scheduling.
    """
    document = json.loads(Path(matrices_path).read_text())
    cases = document.get("cases") if isinstance(document, dict) else None
    if not isinstance(cases, list) or not cases:
        raise ValueError("array test requires a nonempty list of matrix pairs in 'cases'")
    results = []
    records = []
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("each case must contain A and B matrices")
        a, b = case.get("A"), case.get("B")
        if not isinstance(a, list) or len(a) != 4 or not isinstance(a[0], list):
            raise ValueError("A must have shape 4xK")
        inner = len(a[0])
        if not 1 <= inner <= 256:
            raise ValueError("K must be between 1 and K_MAX=256")
        if any(not isinstance(row, list) or len(row) != inner for row in a):
            raise ValueError("A must have shape 4xK")
        if (not isinstance(b, list) or len(b) != inner or
                any(not isinstance(row, list) or len(row) != 4 for row in b)):
            raise ValueError("B must have shape Kx4 matching A")
        for name, matrix in (("A", a), ("B", b)):
            if any(type(value) is not int or not -128 <= value <= 127
                   for row in matrix for value in row):
                raise ValueError(f"{name} entries must be signed INT8 integers")
        c = matrix_multiply(a, b, data_w=8, k_max=256, acc_w=24)
        results.append({"K": inner, "A": a, "B": b, "C": c})
        records.append(f"{inner}\n")
        a_flat = [value for row in a for value in row]
        b_flat = [value for row in b for value in row]
        records.extend(f"{av & 0xff:02x} {bv & 0xff:02x}\n"
                       for av, bv in zip(a_flat, b_flat))
        records.extend(f"{value & 0xffffff:06x}\n" for row in c for value in row)
    vectors_path = Path(vectors_path)
    vectors_path.parent.mkdir(parents=True, exist_ok=True)
    vectors_path.write_text("".join(records))
    if results_path is not None:
        results_path = Path(results_path)
        results_path.parent.mkdir(parents=True, exist_ok=True)
        results_path.write_text(json.dumps({"DATA_W": 8, "ACC_W": 24,
                                           "cases": results}, indent=2) + "\n")
    return results


def array_stream(count=100, seed=20261105):
    """Reproducible directed corners followed by full-range random INT8 pairs."""
    if type(count) is not int or count < 1:
        raise ValueError("stream count must be a positive integer")
    rng = random.Random(seed)
    def random_matrix():
        return [[rng.randint(-128, 127) for _ in range(4)] for _ in range(4)]

    identity = [[int(row == col) for col in range(4)] for row in range(4)]
    zero = [[0]*4 for _ in range(4)]
    low = [[-128]*4 for _ in range(4)]
    high = [[127]*4 for _ in range(4)]
    alternating = [[-128 if (row+col) % 2 else 127 for col in range(4)]
                   for row in range(4)]
    cases = [{"A": zero, "B": random_matrix()},
             {"A": identity, "B": random_matrix()},
             {"A": random_matrix(), "B": identity},
             {"A": low, "B": low}, {"A": low, "B": high},
             {"A": high, "B": high}, {"A": alternating, "B": alternating},
             {"A": [[-1]*4 for _ in range(4)], "B": [[1]*4 for _ in range(4)]}]
    while len(cases) < count:
        cases.append({"A": random_matrix(), "B": random_matrix()})
    return {"seed": seed, "cases": cases[:count]}


def array_sizes(seed=20261105):
    """Vary dot-product length while keeping every output tile exactly 4x4."""
    rng = random.Random(seed)
    cases = []
    for inner in (1, 1, 2, 3, 4, 5, 7, 8, 16, 31, 64, 128, 256, 1, 1):
        a = [[rng.randint(-128, 127) for _ in range(inner)] for _ in range(4)]
        b = [[rng.randint(-128, 127) for _ in range(4)] for _ in range(inner)]
        if inner == 256:
            a = [[-128]*inner for _ in range(4)]
            b = [[-128]*4 for _ in range(inner)]
        cases.append({"A": a, "B": b})
    return {"seed": seed, "cases": cases}


def pe_step(state, signals, data_w, acc_w):
    """State: accumulator, A-out, B-out, A-valid-out, B-valid-out."""
    rst, clear, en, av, bv, a, b = signals
    if rst or clear:
        return (0, 0, 0, 0, 0)
    if not en:
        return state
    acc = mac(state[0], a, b, data_w, acc_w) if av and bv else state[0]
    return (acc, signed(a, data_w), signed(b, data_w), av, bv)


def pe_vectors(data_w, k_max, acc_w):
    validate_config(data_w, k_max, acc_w)
    rng = random.Random(SEED + data_w)
    low, high = -(1 << (data_w - 1)), (1 << (data_w - 1)) - 1
    state, count = (0, 0, 0, 0, 0), 0
    signals = [
        (1, 0, 0, 1, 1, low, low),
        (0, 0, 1, 1, 1, 1, 1),
        (0, 0, 1, 1, 0, low, high),
        (0, 0, 1, 0, 1, high, low),
        (0, 0, 1, 0, 0, high, high),
        (0, 0, 0, 1, 1, low, low),
        (0, 1, 0, 1, 1, high, high),
        (1, 1, 1, 1, 1, low, low),
    ]
    for a, b in ((low, low), (high, high), (low, high), (0, high)):
        signals.append((0, 1, 1, 1, 1, a, b))
        signals.extend([(0, 0, 1, 1, 1, a, b)] * k_max)
    for _ in range(300):
        signals.append((int(rng.randrange(40) == 0), int(rng.randrange(30) == 0),
                        rng.randrange(2), rng.randrange(2), rng.randrange(2),
                        rng.randint(low, high), rng.randint(low, high)))
    for signal in signals:
        rst, clear, en, av, bv, _, _ = signal
        if rst or clear:
            count = 0
        elif en and av and bv:
            if count == k_max:
                clearing = (0, 1, 0, 0, 0, 0, 0)
                state = pe_step(state, clearing, data_w, acc_w)
                yield clearing + state
                count = 0
            count += 1
        state = pe_step(state, signal, data_w, acc_w)
        yield signal + state


@dataclass(frozen=True)
class ClockedPEState:
    accumulator: int = 0
    a_out: int = 0
    b_out: int = 0
    a_valid_out: int = 0
    b_valid_out: int = 0
    result: int = 0
    result_valid: int = 0


def clocked_pe_step(state, signals, data_w, acc_w):
    """Integer reference, independent of the RTL's two-vector representation."""
    rst, clear, drain, en, av, bv, a, b = signals
    if rst or clear:
        return ClockedPEState()
    next_state = replace(state, accumulator=0 if drain else state.accumulator,
                         result=state.accumulator if drain else state.result,
                         result_valid=int(bool(drain)))
    if not en:
        return next_state
    acc = mac(next_state.accumulator, a, b, data_w, acc_w) if av and bv else next_state.accumulator
    return replace(next_state, accumulator=acc, a_out=signed(a, data_w),
                   b_out=signed(b, data_w), a_valid_out=av, b_valid_out=bv)


def clocked_pe_vectors(data_w, k_max, acc_w):
    validate_config(data_w, k_max, acc_w)
    rng = random.Random(SEED + data_w)
    low, high = -(1 << (data_w - 1)), (1 << (data_w - 1)) - 1
    # Fields are reset, clear, drain, enable, A-valid, B-valid, A, B.
    clearing = (0, 1, 0, 0, 0, 0, 0, 0)
    idle = (0, 0, 0, 0, 1, 1, low, high)
    signals = [
        (1, 0, 0, 0, 1, 1, low, low),
        (0, 0, 1, 0, 1, 1, low, high),  # drain zero while disabled
        idle,
        (0, 0, 0, 1, 1, 1, 1, 1),
        (0, 0, 0, 1, 1, 0, low, high),
        (0, 0, 0, 1, 0, 1, high, low),
        (0, 0, 0, 1, 0, 0, high, high),
        idle,
        (0, 0, 1, 1, 1, 1, low, low),  # publish old sum and start the next tile
        idle,                           # valid clears, result still holds
        (0, 0, 1, 0, 0, 0, 0, 0),
        (0, 0, 1, 1, 1, 1, high, high),  # publish zero and accept a new product
        (0, 0, 0, 1, 1, 1, -1, 1),     # continue the sum started on drain
        (0, 0, 1, 0, 0, 0, 0, 0),
        (0, 1, 1, 1, 1, 1, low, low),  # clear wins over drain/en
        (1, 1, 1, 1, 1, 1, low, low),  # reset wins over everything
        (0, 0, 0, 1, 1, 1, low, high),
        clearing,                       # clear in the middle of an operation
        (0, 0, 0, 1, 1, 1, 1, -1),
        (0, 0, 1, 0, 0, 0, 0, 0),
    ]
    lengths = sorted({k for k in (1, 2, 3, 7, 16, 31, 64, k_max) if k <= k_max})
    for length in lengths:
        for pattern in ("random", "minimum", "maximum", "alternating", "zero", "identity"):
            signals.append(clearing)
            for index in range(length):
                if pattern == "random":
                    a, b = rng.randint(low, high), rng.randint(low, high)
                elif pattern == "minimum":
                    a, b = low, low
                elif pattern == "maximum":
                    a, b = high, high
                elif pattern == "alternating":
                    a, b = (low, high) if index % 2 else (high, high)
                elif pattern == "zero":
                    a, b = 0, high
                else:
                    a, b = rng.randint(low, high), 1
                if index % 5 == 2:
                    signals.append(idle)
                if index % 7 == 3:
                    signals += [(0, 0, 0, 1, 1, 0, low, high),
                                (0, 0, 0, 1, 0, 1, high, low)]
                signals.append((0, 0, 0, 1, 1, 1, a, b))
            signals += [(0, 0, 1, 0, 1, 1, low, low), idle,
                        (0, 0, 1, 1, 1, 1, high, high), idle]
    # Exercise every drain/enable/valid combination after a known nonzero sum.
    for drain in (0, 1):
        for en in (0, 1):
            for av in (0, 1):
                for bv in (0, 1):
                    signals += [clearing, (0, 0, 0, 1, 1, 1, 1, 1),
                                (0, 0, drain, en, av, bv, low, high)]
    # Continuous tiles: every edge accepts a product, including boundary edges.
    signals.append(clearing)
    for tile in range(4):
        for index in range(min(k_max, 4)):
            signals.append((0, 0, int(tile > 0 and index == 0), 1, 1, 1,
                            rng.randint(low, high), rng.randint(low, high)))
    signals.append((0, 0, 1, 0, 0, 0, 0, 0))  # publish the final tile
    if data_w >= 7 and k_max >= 2:
        # F=4 fixed-point example: 1.5*(-2) + 0.5*1 = -2.5; raw result=-640.
        signals += [clearing, (0, 0, 0, 1, 1, 1, 24, -32),
                    (0, 0, 0, 1, 1, 1, 8, 16), (0, 0, 1, 0, 0, 0, 0, 0), idle]
    for _ in range(500):
        signals.append((int(rng.randrange(40) == 0), int(rng.randrange(30) == 0),
                        int(rng.randrange(8) == 0), rng.randrange(2),
                        rng.randrange(2), rng.randrange(2),
                        rng.randint(low, high), rng.randint(low, high)))
    signals += [(0, 0, 1, 0, 0, 0, 0, 0), idle]

    state, accepted = ClockedPEState(), 0
    for signal in signals:
        rst, clear, drain, en, av, bv, _, _ = signal
        if rst or clear or drain:
            accepted = 0
        if not rst and not clear and en and av and bv:
            if accepted == k_max:
                state = clocked_pe_step(state, clearing, data_w, acc_w)
                yield clearing, state
                accepted = 0
            accepted += 1
        state = clocked_pe_step(state, signal, data_w, acc_w)
        yield signal, state


def write_vectors(module, width, path, k_max=256, acc_w=None, rows=7):
    """One whitespace-separated hexadecimal record per test stimulus."""
    if width < 1:
        raise ValueError("width must be positive")
    mask = (1 << width) - 1
    rng = random.Random(SEED + width)
    if module == "signed_multiplier":
        if width < 2:
            raise ValueError("DATA_W must be >= 2")
        low, high = -(1 << (width - 1)), (1 << (width - 1)) - 1
        if width <= 8:
            pairs = ((a, b) for a in range(low, high + 1) for b in range(low, high + 1))
        else:
            corners = (low, low + 1, -1, 0, 1, high)
            pairs = [(a, b) for a in corners for b in corners]
            pairs += [(rng.randint(low, high), rng.randint(low, high)) for _ in range(1000)]
        rows = ((a & mask, b & mask, (a * b) & ((1 << (2 * width)) - 1)) for a, b in pairs)
    elif module == "compressor_tree":
        if rows < 1:
            raise ValueError("ROWS must be positive")
        total_bits = width * rows
        if total_bits <= 10:
            packed_inputs = range(1 << total_bits)
        else:
            packed_inputs = [0, (1 << total_bits) - 1,
                sum(1 << (index * width) for index in range(rows)),
                sum(1 << (index * width + width - 1) for index in range(rows)),
                sum(mask << (index * width) for index in range(rows) if index % 2)]
            packed_inputs += [1 << bit for bit in range(total_bits)]
            packed_inputs += [rng.getrandbits(total_bits) for _ in range(1024)]
        output_rows = rows
        rows = ((packed, sum((packed >> (index * width)) & mask
                            for index in range(output_rows)) & mask)
                for packed in packed_inputs)
    elif module == "booth_mac_datapath":
        acc_w = minimum_acc_width(width, k_max) if acc_w is None else acc_w
        validate_config(width, k_max, acc_w)
        acc_mask = (1 << acc_w) - 1
        low, high = -(1 << (width - 1)), (1 << (width - 1)) - 1
        corners = (low, low + 1, -1, 0, 1, high)
        states = ((0, 0), (acc_mask, 1),
                  (1 << (acc_w - 1), 1 << (acc_w - 1)), (acc_mask, acc_mask))
        cases = [(a, b, s, c) for a in corners for b in corners for s, c in states]
        cases += [(rng.randint(low, high), rng.randint(low, high),
                   rng.getrandbits(acc_w), rng.getrandbits(acc_w)) for _ in range(1024)]
        rows = ((a & mask, b & mask, s, c, (a * b + s + c) & acc_mask)
                for a, b, s, c in cases)
    elif module == "booth_pp_gen":
        if width < 2:
            raise ValueError("DATA_W must be >= 2")
        low, high = -(1 << (width - 1)), (1 << (width - 1)) - 1
        values = range(low, high + 1) if width <= 8 else (
            [low, low + 1, -1, 0, 1, high] +
            [rng.randint(low, high) for _ in range(1000)])
        # Include negative zero as a robustness check, even though the recoder
        # emits only positive zero. Do not exercise illegal one=two=1 controls.
        controls = ((0, 0, 0), (0, 1, 0), (0, 0, 1),
                    (1, 0, 0), (1, 1, 0), (1, 0, 1))
        bias = 1 << (width + 1)
        # Arithmetic oracle, independent of the RTL's select/XOR/inversion logic.
        rows = ((x & mask, sign, one, two,
                 bias + (-1 if sign else 1) * (one + 2 * two) * x - sign, sign)
                for x in values for sign, one, two in controls)
    elif module == "ripple_carry_adder":
        values = range(mask + 1) if width <= 4 else (0, 1, mask >> 1, mask)
        triples = [(a, b, c) for a in values for b in values for c in (0, 1)]
        if width > 4:
            triples += [(rng.getrandbits(width), rng.getrandbits(width), rng.randrange(2))
                        for _ in range(1000)]
        rows = ((a, b, c, (a + b + c) & mask, (a + b + c) >> width)
                for a, b, c in triples)
    elif module == "carry_save_adder":
        values = range(mask + 1) if width <= 3 else (0, 1, mask >> 1, mask)
        triples = [(a, b, c) for a in values for b in values for c in values]
        if width > 3:
            triples += [(rng.getrandbits(width), rng.getrandbits(width), rng.getrandbits(width))
                        for _ in range(1000)]
        rows = ((a, b, c, a ^ b ^ c, (((a & b) | (a & c) | (b & c)) << 1) & mask)
                for a, b, c in triples)
    elif module == "pe_booth_csa":
        acc_w = minimum_acc_width(width, k_max) if acc_w is None else acc_w
        acc_mask = (1 << acc_w) - 1
        rows = ((rst, clear, drain, en, av, bv, a & mask, b & mask,
                 state.accumulator & acc_mask, state.a_out & mask, state.b_out & mask,
                 state.a_valid_out, state.b_valid_out, state.result & acc_mask, state.result_valid)
                for (rst, clear, drain, en, av, bv, a, b), state
                in clocked_pe_vectors(width, k_max, acc_w))
    elif module == "pe":
        acc_w = minimum_acc_width(width, k_max) if acc_w is None else acc_w
        rows = ((rst, clear, en, av, bv, a & mask, b & mask,
                 acc & ((1 << acc_w) - 1), ao & mask, bo & mask, avo, bvo)
                for rst, clear, en, av, bv, a, b, acc, ao, bo, avo, bvo
                in pe_vectors(width, k_max, acc_w))
    else:
        raise ValueError(f"no vector generator for {module}")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w") as output:
        for row in rows:
            output.write(" ".join(f"{value:x}" for value in row) + "\n")
            count += 1
    return count


def generate_test_vectors():
    for module in ("ripple_carry_adder", "carry_save_adder", "signed_multiplier", "pe",
                   "booth_pp_gen", "compressor_tree", "booth_mac_datapath", "pe_booth_csa"):
        for width in WIDTHS:
            path = ROOT / "vectors" / f"{module}_{width}.txt"
            count = write_vectors(module, width, path)
            print(f"{path.relative_to(ROOT.parent)}: {count} cases (seed {SEED + width})")
    a, b = [[1, 2], [3, 4]], [[5, 6], [7, 8]]
    expected = ROOT / "expected"
    expected.mkdir(parents=True, exist_ok=True)
    (expected / "matrix_example.json").write_text(json.dumps({
        "A": a, "B": b, "C": matrix_multiply(a, b), "DATA_W": 8,
        "K_MAX": 256, "ACC_W": 24}, indent=2) + "\n")
    write_array_vectors(ROOT / "array_matrices.json",
                        ROOT / "vectors/systolic_4_4_array.txt",
                        expected / "array_results.json")


if __name__ == "__main__":
    generate_test_vectors()
