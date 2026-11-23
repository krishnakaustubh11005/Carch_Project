#!/usr/bin/env python3
"""Check the log of fpga/tb_fpga_run.v (make fpga-run-sim).

For every job: decode the result words (same protocol as fpga/run.tcl),
check C = A x B for dumped matrices, check that pseudo-random A and B match
the firmware's xorshift32 stream for the seed, check PASS/FAIL against what
the configuration should give, and check that the report burst fits one ILA
window (4096 samples, trigger at sample 8; fpga/build.tcl).
"""
import re
import sys

ILA_WINDOW = 4096 - 8


def s8(x):
    return x - 256 if x > 127 else x


def s32(x):
    return x - (1 << 32) if x >> 31 else x


def xorshift_bytes(seed, count):
    x = seed or 1
    out = []
    for _ in range(count):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out.append(s8(x >> 24))
    return out


def decode(words):
    """Return dict with matrices, bench row and final word (fpga/run.tcl protocol)."""
    res, i = {"mats": {}}, 0
    while i < len(words):
        t = words[i]; i += 1
        if t >> 8 == 0xCA0000:
            rows, cols = words[i], words[i + 1]; i += 2
            kind = t & 0xFF
            if kind == 0xC4:
                vals = [s32(w) for w in words[i:i + rows * cols]]; i += rows * cols
            else:
                n = (rows * cols + 3) // 4
                vals = [s8(w >> (8 * b) & 0xFF) for w in words[i:i + n] for b in range(4)][:rows * cols]
                i += n
            res["mats"][{0xA1: "A", 0xB1: "B", 0xC4: "C"}[kind]] = (rows, cols, vals)
        elif t >> 24 == 0xD0:
            count = t & 0xFF                     # 7 (old firmware) or 8 (+ instructions)
            res["bench"] = words[i:i + count]; i += count
        else:
            res["final"] = t
    return res


def main(path):
    jobs, words, clocks, monitors = {}, {}, {}, {}
    for line in open(path):
        f = line.split()
        if not f:
            continue
        if f[0] == "J" and f[2] != "power-up":
            kv = dict(x.split("=") for x in f[2:])
            jobs[int(f[1])] = {k: int(v, 16) for k, v in kv.items()}
        elif f[0] == "J":
            jobs[0] = {"ctrl": 0x00210204, "seed": 1,
                       "a": 0x03FE0100_0002FD05_020100FF_04030201,
                       "b": 0x02FF0101_0100FE03_00010100_FF020001}
        elif f[0] == "W":
            words.setdefault(int(f[1]), []).append(int(f[3], 16))
            clocks.setdefault(int(f[1]), []).append(int(f[2]))
        elif f[0] == "M":
            monitors[int(f[1])] = line.strip()
    if "DONE" not in open(path).read():
        sys.exit("FAIL: testbench did not finish")

    failures = 0
    for j, cfg in sorted(jobs.items()):
        ctrl = cfg["ctrl"]
        m, k, n, mat = ctrl & 0x7F, ctrl >> 7 & 0x7F, ctrl >> 14 & 0x7F, ctrl >> 21 & 1
        bad = not (1 <= m <= 64 and 1 <= k <= 64 and 1 <= n <= 64) or (mat and (m * k > 16 or k * n > 16))
        r = decode(words.get(j, []))
        span = clocks[j][-1] - clocks[j][0] if j in clocks else 0
        problems = []
        if bad:
            if r.get("final", 1) >> 28 != 0xF or (r["final"] >> 16 & 0xFFF) != 4:
                problems.append(f"expected config FAIL (test 4), got {r.get('final', 0):08X}")
        else:
            if r.get("final") != 1:
                problems.append(f"final {r.get('final', 0):08X} != PASS")
            b = r.get("bench")
            if not b or b[:3] != [m, k, n]:
                problems.append(f"benchmark row {b}")
            if "A" in r["mats"]:
                A, B, C = (r["mats"][x][2] for x in "ABC")
                if mat:
                    wantA = [s8(cfg["a"] >> (8 * i) & 0xFF) for i in range(m * k)]
                    wantB = [s8(cfg["b"] >> (8 * i) & 0xFF) for i in range(k * n)]
                else:
                    stream = xorshift_bytes(cfg["seed"], m * k + k * n)
                    wantA, wantB = stream[:m * k], stream[m * k:]
                if A != wantA or B != wantB:
                    problems.append("A/B differ from the configured data")
                wantC = [sum(A[i * k + t] * B[t * n + jj] for t in range(k)) for i in range(m) for jj in range(n)]
                if C != wantC:
                    problems.append("C != A x B")
            elif max(m, k, n) <= 8:
                problems.append("matrices missing")
        if span > ILA_WINDOW:
            problems.append(f"report burst spans {span} clocks > ILA window {ILA_WINDOW}")
        b = (r.get("bench") or []) + [0] * 8
        speed = f"{b[3] / b[4]:.1f}x" if b[4] else "-"
        instr = b[7]
        if not bad and not instr:
            problems.append("no instruction count in the benchmark row")
        elif instr and not 1.0 < b[3] / instr < 10.0:
            problems.append(f"CPI {b[3] / instr:.2f} outside 1..10")
        cpu = f", {instr} instr, CPI {b[3] / instr:.2f}, {b[3] / (m * k * n):.1f} cyc/MAC" if instr else ""
        status = "ok" if not problems else "FAIL: " + "; ".join(problems)
        print(f"job {j}: {m}x{k}x{n} {'matrix' if mat else 'seed ' + str(cfg['seed'])}: "
              f"final {r.get('final', 0):08X}, sw {b[3]}, accel {b[4]} (fetch {b[5]}, compute {b[6]}), "
              f"{speed}{cpu}, burst {span} clk -> {status}")
        failures += bool(problems)
    for j in sorted(monitors):
        print(monitors[j])
    print("PASS" if failures == 0 else f"FAIL ({failures} jobs)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main(sys.argv[1])
