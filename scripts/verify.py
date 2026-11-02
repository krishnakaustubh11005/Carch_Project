#!/usr/bin/env python3
"""Dependency-aware Verilog verification; pending hardware never counts as PASS."""

import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "golden"))
import model

DEPENDENCIES = {
    "half_adder": (),
    "full_adder": ("half_adder",),
    "booth_recoder": (),
    "booth_pp_gen": (),
    "compressor_tree": ("full_adder",),
    "booth_mac_datapath": ("booth_recoder", "booth_pp_gen", "compressor_tree"),
    "ripple_carry_adder": ("full_adder",),
    "carry_save_adder": ("full_adder",),
    "signed_multiplier": ("booth_mac_datapath",),
    "pe_booth_csa": ("booth_mac_datapath",),
}
# Preserve the short Makefile command without adding a second hardware wrapper.
# tb_pe.v is the retained, pre-drain interface template and is not an active test.
TEST_ALIASES = {"pe": "pe_booth_csa"}
DEFAULT_WIDTHS = {
    "booth_pp_gen": model.WIDTHS,
    "compressor_tree": (1, 2, 3, 8, 16, 24, 40),
    "booth_mac_datapath": model.WIDTHS,
    "ripple_carry_adder": (1, 2, 3, 4, 8, 16, 32, 40),
    "carry_save_adder": (1, 2, 3, 4, 8, 16, 32),
    "signed_multiplier": model.WIDTHS,
    "pe": model.WIDTHS,
    "pe_booth_csa": model.WIDTHS,
}


def sources(root, module):
    result = []

    def visit(name):
        for child in DEPENDENCIES.get(name, ()):
            visit(child)
        path = root / "rtl" / f"{name}.v"
        if path not in result:
            result.append(path)

    visit(module)
    return result


def discover(root):
    found = {path.stem[3:] for path in (root / "tb").glob("tb_*.v")}
    found -= TEST_ALIASES.keys()
    return [name for name in DEPENDENCIES if name in found] + sorted(found - DEPENDENCIES.keys())


def valid_name(name):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name or ""):
        raise ValueError("module must be a nonempty Verilog identifier")
    return name


def execute(command, root, timeout):
    try:
        result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return 124, output + f"\nTIMEOUT after {timeout}s\n"
    except OSError as error:
        return 127, str(error) + "\n"


def passed(returncode, output):
    lines = {line.strip() for line in output.splitlines()}
    return returncode == 0 and "TEST PASSED" in lines and "TEST FAILED" not in lines


def run_case(root, module, width, options):
    label = module if width is None else f"{module}[{width}]"
    build = root / "sim" / "build"
    (build / "logs").mkdir(parents=True, exist_ok=True)
    (root / "sim" / "vcd").mkdir(parents=True, exist_ok=True)
    suffix = module if width is None else f"{module}_{width}"
    binary, log = build / f"tb_{suffix}.vvp", build / "logs" / f"{suffix}.log"
    top = f"tb_{module}"
    command = shlex.split(options.iverilog) + ["-g2001", "-I", str(root / "tb"),
              "-s", top, "-o", str(binary)]
    simulator_args = []
    if width is not None:
        parameter = "DATA_W" if module in ("booth_pp_gen", "booth_mac_datapath", "signed_multiplier", "pe_booth_csa") else "WIDTH"
        command += [f"-P{top}.{parameter}={width}"]
        acc_w = None
        if module in ("booth_mac_datapath", "pe_booth_csa"):
            acc_w = options.acc_w if options.acc_w is not None else model.minimum_acc_width(width, options.k_max)
            model.validate_config(width, options.k_max, acc_w)
            command += [f"-P{top}.ACC_W={acc_w}"]
            if module == "pe_booth_csa":
                command += [f"-P{top}.K_MAX={options.k_max}"]
        if module == "compressor_tree":
            command += [f"-P{top}.ROWS={options.rows}"]
        vectors = build / "vectors" / f"{suffix}.txt"
        model.write_vectors(module, width, vectors, options.k_max, acc_w, rows=options.rows)
        simulator_args.append(f"+VECTOR_FILE={vectors}")
    command += [str(root / "tb" / f"{top}.v")] + [str(path) for path in sources(root, module)]
    code, output = execute(command, root, options.timeout)
    metadata = f"# {label}"
    if width is not None:
        metadata += f"; reference seed={model.SEED + width}"
    if module in ("booth_mac_datapath", "pe_booth_csa"):
        metadata += f"; ACC_W={acc_w}"
    if module == "pe_booth_csa":
        metadata += f"; K_MAX={options.k_max}"
    if module == "compressor_tree":
        metadata += f"; ROWS={options.rows}"
    transcript = metadata + "\n$ " + shlex.join(command) + "\n" + output
    if code == 0:
        sim_command = shlex.split(options.vvp) + [str(binary)] + simulator_args
        code, output = execute(sim_command, root, options.timeout)
        transcript += "$ " + shlex.join(sim_command) + "\n" + output
        ok = passed(code, output)
        reason = "all checks passed" if ok else f"simulation failed or missing success marker (exit {code})"
    else:
        ok, reason = False, f"compilation failed (exit {code})"
    log.write_text(transcript)
    if not ok:
        print(transcript.rstrip())
    return {"module": label, "status": "PASS" if ok else "FAIL", "reason": reason,
            "log": str(log.relative_to(root))}


def show_report(records):
    for record in records:
        print(f"{record['status']:7} {record['module']}: {record['reason']}")
    counts = {status: sum(row["status"] == status for row in records)
              for status in ("PASS", "FAIL", "PENDING")}
    print("Summary: " + ", ".join(f"{count} {status}" for status, count in counts.items()))
    if counts["PENDING"]:
        print("INCOMPLETE: pending modules are not verified hardware.")
    if not records:
        print("INCOMPLETE: no testbenches discovered.")
    return counts


def test(root, options):
    names = [TEST_ALIASES.get(valid_name(options.module), options.module)] if options.module else discover(root)
    explicit_widths = tuple(int(value) for value in options.widths.split())
    if any(width < 1 for width in explicit_widths):
        raise ValueError("WIDTHS must contain positive integers")
    if options.k_max < 1 or options.timeout <= 0 or options.rows < 1:
        raise ValueError("K_MAX, ROWS, and TIMEOUT must be positive")
    records = []
    for name in names:
        widths = explicit_widths or DEFAULT_WIDTHS.get(name, (None,))
        if name in ("half_adder", "full_adder") or name not in DEFAULT_WIDTHS:
            widths = (None,)
        for width in widths:
            if name in ("booth_pp_gen", "booth_mac_datapath", "signed_multiplier", "pe_booth_csa") and width < 2:
                raise ValueError("DATA_W must be >= 2")
            if name in ("booth_mac_datapath", "pe_booth_csa"):
                model.validate_config(width, options.k_max,
                                      options.acc_w if options.acc_w is not None
                                      else model.minimum_acc_width(width, options.k_max))
        needed = [root / "tb" / f"tb_{name}.v"] + sources(root, name)
        missing = [str(path.relative_to(root)) for path in needed if not path.is_file()]
        if missing:
            records.append({"module": name, "status": "PENDING", "reason": "missing " + ", ".join(missing)})
            continue
        for width in widths:
            records.append(run_case(root, name, width, options))
    report = root / "sim" / "build" / "report.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(records, indent=2) + "\n")
    counts = show_report(records)
    return int(bool(counts["FAIL"] or ((options.strict or options.module) and
                    (counts["PENDING"] or not records))))


def lint(root, options):
    if options.timeout <= 0:
        raise ValueError("TIMEOUT must be positive")
    tool = shlex.split(options.verilator)
    if not tool or shutil.which(tool[0]) is None:
        print("SKIP lint: Verilator unavailable; no lint result claimed.")
        return 0
    failed, checked = False, 0
    for name in discover(root):
        required = sources(root, name)
        if any(not path.is_file() for path in required):
            print(f"PENDING lint {name}: missing RTL dependencies")
            continue
        command = tool + ["--lint-only", "--Wall", "--top-module", name] + list(map(str, required))
        code, output = execute(command, root, options.timeout)
        print(output.rstrip())
        print(f"{'PASS' if code == 0 else 'FAIL'} lint {name}")
        checked += 1
        failed |= code != 0
    if checked == 0:
        print("SKIP lint: no complete hardware modules.")
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("test", "lint", "summary", "wave", "clean"))
    parser.add_argument("--module")
    parser.add_argument("--widths", default="")
    parser.add_argument("--k-max", type=int, default=256)
    parser.add_argument("--acc-w", type=int)
    parser.add_argument("--rows", type=int, default=7)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--gtkwave", default="gtkwave")
    options = parser.parse_args()
    try:
        if options.action == "test":
            return test(ROOT, options)
        if options.action == "lint":
            return lint(ROOT, options)
        if options.action == "summary":
            path = ROOT / "sim" / "build" / "report.json"
            if not path.exists():
                print("No report yet; run make test.")
                return 1
            show_report(json.loads(path.read_text()))
            return 0
        if options.action == "wave":
            name = TEST_ALIASES.get(valid_name(options.module), options.module)
            path = ROOT / "sim" / "vcd" / f"{name}.vcd"
            if not path.is_file():
                raise ValueError(f"no waveform; first run make test-{name}")
            # GUI invocation may require environment approval.
            return subprocess.call(shlex.split(options.gtkwave) + [str(path)], cwd=ROOT)
        if options.action == "clean":
            for path in (ROOT / "sim" / "build", ROOT / "sim" / "vcd",
                         ROOT / "golden" / "vectors", ROOT / "golden" / "expected"):
                if path.exists():
                    shutil.rmtree(path)
            print("Removed generated build, waveform, and vector directories.")
            return 0
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
