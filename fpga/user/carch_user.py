#!/usr/bin/env python3
"""Build, simulate and run user C programs on Carch (fpga/user/README.md).

    python3 fpga/user/carch_user.py build  prog.c
    python3 fpga/user/carch_user.py sim    prog.c [--max-clocks N]
    python3 fpga/user/carch_user.py board  prog.c
    python3 fpga/user/carch_user.py mmi    (once per new bitstream; board does it if needed)

Each run makes fpga/user/runs/<time>/ with job.c, the build output and
results.json; the web page (server.py) uses the same functions.

Pipeline:
  build  gcc (rv32im, no divide instruction) start.S + carch.c + your .c
         -> .elf -> .bin -> .hex ($readmemh, simulation) and .mem (updatemem)
  sim    Icarus: fpga_top with ENABLE_ACCEL = 0 and 1 runs the .hex
  board  updatemem puts the .mem into fpga/out_baseline and fpga/out
         fpga_top.bit (no rebuild), then Vivado (batch, fpga/user/board.tcl)
         programs each one, reruns it with the VIO reset and reads the
         result words back through the ILA.
The board steps run Windows Vivado from WSL on the Windows copy of the repo
(CARCH_WIN_ROOT, default /mnt/c/carch; Vivado bin folder CARCH_VIVADO_BIN,
default D:\\carch-vivado\\2025.2\\Vivado\\bin).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import bin2hex  # noqa: E402
import build_fw  # noqa: E402

RUNS = HERE / "runs"
WIN_ROOT = Path(os.environ.get("CARCH_WIN_ROOT", "/mnt/c/carch"))
VIVADO_BIN = os.environ.get("CARCH_VIVADO_BIN", r"D:\carch-vivado\2025.2\Vivado\bin")
MHZ = 50
RAM_WORDS = 1 << 14
CODE_LIMIT = 0xE000
CFLAGS = ["-march=rv32im", "-mabi=ilp32", "-mno-div", "-O2", "-ffreestanding",
          "-nostdlib", "-Wall", "-g", "-Wl,--no-warn-rwx-segments"]
BUILDS = {  # name -> (ENABLE_ACCEL, folder under fpga/)
    "cpu": (0, "out_baseline"),
    "accel": (1, "out"),
}
LABELS = {"cpu": "CPU only", "accel": "CPU + accelerator"}
RECORD = ["version", "accel_present", "total_cycles", "total_instructions",
          "mm_calls", "mm_accel_calls", "mm_cycles", "mm_instructions",
          "fetch_cycles", "compute_cycles", "macs", "macs_accel", "result",
          "printed", "accel_errors", "dropped"]


class RunError(Exception):
    pass


def log_to(logfn):
    return logfn or (lambda line: print(line, flush=True))


def new_run_dir(code):
    RUNS.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    d = RUNS / stamp
    n = 1
    while d.exists():
        d = RUNS / f"{stamp}_{n}"
        n += 1
    d.mkdir()
    (d / "job.c").write_text(code)
    return d


def run(cmd, logfn, cwd=None, timeout=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    out = (p.stdout + p.stderr).strip()
    if out:
        for line in out.splitlines()[-60:]:
            logfn("  " + line)
    if p.returncode:
        raise RunError(f"{Path(cmd[0]).name} failed (exit {p.returncode})")
    return out


# ---------------------------------------------------------------- build
def build(run_dir, logfn=None):
    logfn = log_to(logfn)
    tool = build_fw.find_prefix()
    if tool is None:
        raise RunError("RISC-V toolchain not found (set RISCV_PREFIX)")
    elf, binary = run_dir / "prog.elf", run_dir / "prog.bin"
    logfn("build: gcc " + " ".join(CFLAGS))
    run([tool + "gcc", *CFLAGS, "-I", str(HERE), "-T", str(HERE / "link.ld"), "-o", str(elf),
         str(HERE / "start.S"), str(HERE / "carch.c"), str(run_dir / "job.c"), "-lgcc"], logfn)
    run([tool + "objcopy", "-O", "binary", str(elf), str(binary)], logfn)
    sizes = run([tool + "size", "-A", str(elf)], lambda _: None)
    end = 0
    for line in sizes.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0] in (".text", ".rodata", ".data", ".bss"):
            end = max(end, int(f[2]) + int(f[1]))
    if end > CODE_LIMIT:
        raise RunError(f"program + data end at 0x{end:X}, past 0x{CODE_LIMIT:X}: make arrays smaller")
    bin2hex.main([str(binary), str(run_dir / "prog.hex"), "--words", str(RAM_WORDS)])
    words = (run_dir / "prog.hex").read_text().split()
    (run_dir / "prog.mem").write_text("@00000000\n" + "\n".join(words) + "\n")
    info = {"code_bytes": binary.stat().st_size, "ram_used": end, "ram_limit": CODE_LIMIT}
    try:
        info["asm"] = disassemble(tool, elf)
    except Exception as e:  # the listing is a bonus; never fail a run on it
        logfn(f"build: no assembly listing ({e})")
    logfn(f"build: ok, {info['code_bytes']} bytes loaded, RAM used up to 0x{end:04X} of 0x{CODE_LIMIT:X}")
    return info


# ---------------------------------------------------------------- assembly listing
ACCEL_REGS = {0: "ID", 4: "CAPS", 8: "CTRL", 12: "STATUS", 16: "ERR", 20: "JOBS", 24: "FETCH",
              28: "COMPUTE", 32: "M", 36: "N", 40: "K", 44: "A_ADDR", 48: "B_ADDR", 52: "C_ADDR",
              56: "IRQ_EN"}
STATS = ("fetch_sum", "compute_sum", "mm_cycles", "mm_instructions", "mm_calls", "mm_accel_calls",
         "macs_all", "macs_accel", "accel_errors", "accel_present")
GENERIC = {
    "lb": "load 1 byte (int8) from RAM", "lbu": "load 1 byte from RAM", "lh": "load 2 bytes",
    "lw": "load a 32-bit word", "sb": "store 1 byte", "sw": "store a 32-bit word to RAM",
    "mul": "multiply (M extension, hardware)", "add": "add", "addi": "add a constant",
    "sub": "subtract", "slli": "shift left (x 2^n)", "srli": "shift right", "andi": "bit mask",
    "lui": "load upper 20 bits of a constant", "auipc": "PC + upper 20 bits",
    "jal": "jump and link", "jalr": "jump to register", "csrrs": "read a CSR",
    "beq": "branch if equal", "bne": "branch if not equal",
    "bltu": "branch if lower (unsigned)", "bgeu": "branch if >= (unsigned)",
    "blt": "branch if less", "bge": "branch if >=", "or": "bitwise or", "ori": "bitwise or with a constant",
    "xor": "bitwise xor", "xori": "bitwise xor with a constant", "and": "bitwise and", "srai": "arithmetic shift right",
}
MAC_LOOP = ["lb", "lb", "addi", "add", "mul", "add", "bne"]
MAC_NOTES = ["load A[i][t] (int8)", "load B[t][j] (int8)", "next A element (+1 byte)",
             "next B element (+N bytes = next row)", "A[i][t] x B[t][j]  (hardware multiply)",
             "sum += product", "loop until t = K"]


def _plain_note(op, a, note):
    """Notes for real instructions that assemblers usually hide behind
    pseudo-instructions (mv, li, j, ret, beqz, rdcycle, ...)."""
    if op == "addi" and len(a) == 3:
        if a[1] == "zero":
            return f"{a[0]} = {a[2]} (load a constant)"
        if a[2] == "0":
            return f"{a[0]} = {a[1]} (copy a register)"
    if op in ("beq", "bne", "blt", "bge") and len(a) == 3 and "zero" in a[:2]:
        other = a[1] if a[0] == "zero" else a[0]
        rel = {"beq": "== 0", "bne": "!= 0",
               "blt": ("> 0" if a[0] == "zero" else "< 0"), "bge": ("<= 0" if a[0] == "zero" else ">= 0")}[op]
        return f"branch if {other} {rel}"
    if op == "jal":
        return "jump (link register zero: no return)" if a and a[0] == "zero" else "call a function (ra = return address)"
    if op == "jalr":
        return "return from the function (jump to ra)" if a and a[0] == "zero" else "jump to a register's address"
    if op.startswith("csrr") and len(a) >= 2:
        return {"cycle": "read the cycle counter (CSR)", "instret": "read the instruction counter (CSR)"}.get(a[1], "read a CSR")
    return note


def _listing(tool, elf, fn):
    out = subprocess.run([tool + "objdump", "-d", "--no-show-raw-insn", "-M", "no-aliases,max",
                          f"--disassemble={fn}", str(elf)],
                         capture_output=True, text=True, check=True).stdout
    rows, inside = [], False
    for line in out.splitlines():
        if line.endswith(f"<{fn}>:"):
            inside = True
            continue
        m = re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*([^#]*?)\s*(?:#\s*(.*))?$", line)
        if inside and m:
            rows.append({"addr": int(m.group(1), 16), "op": m.group(2), "args": m.group(3).strip(),
                         "sym": m.group(4) or ""})
    return rows


def _annotate(rows, kind):
    """Add note and class ('hot' = innermost loop, 'accel' = accelerator
    register access, 'meta' = measurement bookkeeping) to each row."""
    loops = []
    for r in rows:
        if r["op"][0] == "b" or r["op"] == "jal":
            tgt = r["args"].split(",")[-1].split()[0]
            if re.fullmatch(r"[0-9a-f]+", tgt) and int(tgt, 16) <= r["addr"]:
                loops.append((int(tgt, 16), r["addr"]))
    accel_base = {}
    for r in rows:
        op, args = r["op"], r["args"]
        r["note"], r["cls"] = GENERIC.get(op, ""), ""
        a = [x.strip() for x in args.split(",")]
        r["note"] = _plain_note(op, a, r["note"])
        writes = op not in ("sw", "sh", "sb") and op[0] != "b" and a and a[0] != "zero" and a[0]
        if op == "lui" and len(a) == 2 and a[1] == "0x40000":
            accel_base[a[0]] = 0
            r["note"], r["cls"] = "accelerator register block (0x4000_0000)", "accel"
        elif op == "addi" and len(a) == 3 and a[1] in accel_base:
            accel_base[a[0]] = accel_base[a[1]] + int(a[2], 0)
            r["note"], r["cls"] = f"address of {ACCEL_REGS.get(accel_base[a[0]], 'register')}", "accel"
        elif writes and a[0] in accel_base and not (op == "addi" and len(a) == 3 and a[1] in accel_base):
            del accel_base[a[0]]               # register reused for something else
        if op in ("sw", "lw") and len(a) == 2:
            m = re.match(r"(-?\d+)\((\w+)\)", a[1])
            if m and m.group(2) in accel_base:
                reg = ACCEL_REGS.get(accel_base[m.group(2)] + int(m.group(1)), "?")
                r["cls"] = "accel"
                if op == "sw":
                    r["note"] = {"CTRL": "write CTRL = START: the accelerator begins",
                                 "STATUS": "clear DONE / ERROR"}.get(reg, f"write {reg} register")
                else:
                    r["note"] = {"STATUS": "read STATUS: finished yet?"}.get(reg, f"read {reg} counter")
        if any(f"<{name}>" in r["sym"] for name in STATS):
            r["note"], r["cls"] = "measurement bookkeeping (framework only)", "meta"
        if op.startswith("csrr") and any(x in ("cycle", "instret", "cycleh", "instreth") for x in a):
            r["cls"] = "meta"
        if op == "lw" and writes and a[0] in accel_base and r["cls"] != "accel":
            del accel_base[a[0]]

    # The loop that does the work: the one with the multiply (CPU) or the
    # STATUS read (accelerator); otherwise the innermost one.
    def has(l, test):
        return any(test(r) for r in rows if l[0] <= r["addr"] <= l[1])
    key = (lambda r: r["op"] == "mul") if kind == "cpu" else \
          (lambda r: "STATUS" in r["note"]) if kind == "accel" else (lambda r: False)
    work = [l for l in loops if has(l, key)]
    inner = min(work or loops, key=lambda l: l[1] - l[0]) if loops and kind != "dispatch" else None
    if inner:
        body = [r for r in rows if inner[0] <= r["addr"] <= inner[1]]
        for r in body:
            r["cls"] = (r["cls"] + " hot").strip()
        if kind == "cpu" and [r["op"] for r in body] == MAC_LOOP:
            for r, note in zip(body, MAC_NOTES):
                r["note"] = note
        elif kind == "accel":
            body[-1]["note"] = "not done: read STATUS again (the CPU only waits here)"
    return {"rows": rows, "loop": list(inner) if inner else None,
            "loop_len": len([r for r in rows if inner and inner[0] <= r["addr"] <= inner[1]])}


def disassemble(tool, elf):
    return {"cpu": _annotate(_listing(tool, elf, "matmul_cpu"), "cpu"),
            "accel": _annotate(_listing(tool, elf, "matmul_on_accel"), "accel"),
            "dispatch": _annotate(_listing(tool, elf, "matmul"), "dispatch")}


# ---------------------------------------------------------------- decode
def decode(words):
    """Result words -> dict (see carch.c), or None if the record is missing."""
    r, i = None, 0
    while i < len(words):
        w = words[i]
        if w >> 8 == 0xD10000:
            n = w & 0xFF
            r = dict(zip(RECORD, words[i + 1:i + 1 + n]))
            r["prints"] = []
            r["regions"] = []
            i += 1 + n
        elif w >> 24 == 0xD2 and r is not None and i + 1 < len(words):
            v = words[i + 1]
            r["prints"].append([w & 0xFFFFFF, v - (1 << 32) if v >> 31 else v])
            i += 2
        elif w >> 24 == 0xD4 and r is not None and i + 3 < len(words):
            r.setdefault("regions", []).append([w & 0xFFFFFF, *words[i + 1:i + 4]])
            i += 4
        elif w == 0xD3000000 and r is not None:
            r["complete"] = True
            i += 1
        else:
            if r is not None:
                r["final"] = w
            i += 1
    if r is not None:
        r.setdefault("complete", False)
        r["cpi"] = r["total_cycles"] / r["total_instructions"] if r.get("total_instructions") else None
        r["time_us"] = r["total_cycles"] / MHZ
        r["other_cycles"] = r["total_cycles"] - r["mm_cycles"]
    return r


# ---------------------------------------------------------------- simulation
def _sim_binary(accel, logfn):
    out = ROOT / "sim" / "build" / "user"
    out.mkdir(parents=True, exist_ok=True)
    vvp = out / f"tb_user_{accel}.vvp"
    sources = [HERE / "tb_user.v", ROOT / "fpga" / "fpga_top.v", ROOT / "fpga" / "uart_result_bridge.v",
               ROOT / "fpga" / "sim_stubs" / "unisim_stubs.v", ROOT / "fpga" / "sim_stubs" / "vio_cfg.v",
               *sorted((ROOT / "rtl").glob("*.v"))]
    (out / "fw_path.vh").write_text(f'`define FPGA_FIRMWARE "{out / "prog.hex"}"\n')
    if not vvp.exists() or vvp.stat().st_mtime < max(s.stat().st_mtime for s in sources):
        logfn(f"sim: compiling the {'accelerator' if accel else 'CPU-only'} design (once)")
        run([os.environ.get("IVERILOG", "iverilog"), "-g2005", "-I", str(out), "-s", "tb_user",
             f"-Ptb_user.ENABLE_ACCEL={accel}", "-o", str(vvp), *map(str, sources)], logfn)
    return out, vvp


def simulate(run_dir, max_clocks=3000000, logfn=None):
    logfn = log_to(logfn)
    results = {}
    for name, (accel, _) in BUILDS.items():
        out, vvp = _sim_binary(accel, logfn)
        shutil.copy(run_dir / "prog.hex", out / "prog.hex")
        logfn(f"sim: {LABELS[name]} (up to {max_clocks:,} clocks)")
        t0 = time.time()
        p = subprocess.run([os.environ.get("VVP", "vvp"), "-n", str(vvp), f"+max_clocks={max_clocks}"],
                           capture_output=True, text=True)
        (run_dir / f"sim_{name}.log").write_text(p.stdout + p.stderr)
        words = [int(f[2], 16) for f in (l.split() for l in p.stdout.splitlines()) if f[:1] == ["W"]]
        r = decode(words)
        status = next((l for l in p.stdout.splitlines() if l.split()[:1] in (["DONE"], ["TIMEOUT"], ["TRAP"])), "")
        if r is None or not r["complete"]:
            why = "timed out (raise max clocks)" if status.startswith("TIMEOUT") else \
                  "the CPU trapped (bad instruction or address)" if status.startswith("TRAP") else "no result"
            raise RunError(f"sim {LABELS[name]}: {why}")
        logfn(f"sim: {LABELS[name]}: {r['total_cycles']:,} cycles ({time.time() - t0:.0f} s of simulation)")
        results[name] = r
    return results


# ---------------------------------------------------------------- board
def _win(path):
    p = str(Path(path).resolve())
    if not p.startswith("/mnt/") or len(p) < 6:
        raise RunError(f"{p} is not on a Windows drive")
    return p[5].upper() + ":" + p[6:].replace("/", "\\")


def _cmd(args, logfn, timeout=900):
    """Run a Windows command (in WIN_ROOT) from WSL."""
    line = f'cd /d {_win(WIN_ROOT)} && ' + " ".join(args)
    return run(["cmd.exe", "/c", line], logfn, cwd=str(WIN_ROOT), timeout=timeout)


def _vivado(script, args, log, logfn):
    _cmd([VIVADO_BIN + r"\vivado.bat", "-mode", "batch", "-nojournal", "-log", _win(log),
          "-source", _win(script), "-tclargs", *args], logfn)


def _sync_scripts():
    dst = WIN_ROOT / "fpga" / "user"
    dst.mkdir(parents=True, exist_ok=True)
    for f in ("write_mmi.tcl", "board.tcl"):
        shutil.copy(HERE / f, dst / f)


def ensure_mmi(logfn=None):
    logfn = log_to(logfn)
    _sync_scripts()
    for name, (_, folder) in BUILDS.items():
        d = WIN_ROOT / "fpga" / folder
        dcp, mmi = d / "post_route.dcp", d / "ram.mmi"
        if not (d / "fpga_top.bit").exists():
            raise RunError(f"{d}/fpga_top.bit missing: build it first (fpga/build.tcl"
                           f"{' -tclargs baseline' if name == 'cpu' else ''})")
        if mmi.exists() and mmi.stat().st_mtime >= dcp.stat().st_mtime:
            continue
        logfn(f"board: writing the RAM map for {folder} (once per bitstream, ~1 min)")
        _vivado(WIN_ROOT / "fpga" / "user" / "write_mmi.tcl", [_win(dcp), _win(mmi)], d / "write_mmi.log", logfn)


def board(run_dir, logfn=None):
    logfn = log_to(logfn)
    ensure_mmi(logfn)
    wdir = WIN_ROOT / "fpga" / "user_runs" / run_dir.name
    wdir.mkdir(parents=True, exist_ok=True)
    shutil.copy(run_dir / "prog.mem", wdir / "prog.mem")
    jobs = []
    for name, (_, folder) in BUILDS.items():
        d = WIN_ROOT / "fpga" / folder
        bit = wdir / f"{name}.bit"
        logfn(f"board: putting the program into {folder}/fpga_top.bit (updatemem)")
        _cmd([VIVADO_BIN + r"\updatemem.bat", "-force", "-meminfo", _win(d / "ram.mmi"),
              "-data", _win(wdir / "prog.mem"), "-proc", "carch", "-bit", _win(d / "fpga_top.bit"),
              "-out", _win(bit)], lambda line: None)
        jobs += [name, _win(bit), _win(d / "fpga_top.ltx"), _win(wdir / f"{name}.csv")]
    logfn("board: Vivado programs the PYNQ-Z2 and runs both (about 1 minute)")
    try:
        _vivado(WIN_ROOT / "fpga" / "user" / "board.tcl", jobs, wdir / "board.log", logfn)
    except RunError:
        text = (wdir / "board.log").read_text(errors="replace") if (wdir / "board.log").exists() else ""
        hint = next((l for l in text.splitlines() if "CARCH_ERROR" in l or l.startswith("ERROR")), "")
        raise RunError("board run failed: " + (hint or "see " + str(wdir / "board.log")))
    results = {}
    for name in BUILDS:
        words = csv_words(wdir / f"{name}.csv")
        r = decode(words)
        if r is None or not r["complete"]:
            raise RunError(f"board {LABELS[name]}: incomplete capture ({len(words)} words) in {wdir / (name + '.csv')}")
        logfn(f"board: {LABELS[name]}: {r['total_cycles']:,} cycles")
        results[name] = r
    return results


def csv_words(path):
    lines = Path(path).read_text().splitlines()
    head = lines[0].split(",")
    ci_r = next(i for i, h in enumerate(head) if "dbg_result" in h)
    ci_v = next(i for i, h in enumerate(head) if "dbg_valid" in h)
    words = []
    for line in lines[1:]:
        cols = line.split(",")
        if not cols[0].strip().isdigit():
            continue
        if int(cols[ci_v], 16) == 1:
            words.append(int(cols[ci_r], 16) & 0xFFFFFFFF)
    return words


# ---------------------------------------------------------------- FPGA reports
def fpga_reports():
    """Utilization/timing/power of both bitstreams from summary.txt (report_summary)."""
    out = {}
    for name, (_, folder) in BUILDS.items():
        f = WIN_ROOT / "fpga" / folder / "summary.txt"
        if not f.exists():
            continue
        t = f.read_text()
        rep = {}
        for key, label in (("lut", "Slice LUTs"), ("ff", "Slice Registers"),
                           ("bram", "Block RAM Tile"), ("dsp", "DSPs")):
            m = re.search(r"\|\s*" + label + r"\s*\|\s*([\d.]+)\s*\|\s*(\d+)\s*\|\s*([\d.]+)", t)
            if m:
                rep[key] = [float(m.group(1)), int(m.group(2)), float(m.group(3))]
        for key, pat in (("wns", r"WNS=(-?[\d.]+)ns"), ("whs", r"WHS=(-?[\d.]+)ns"),
                         ("fmax", r"max clock about ([\d.]+) MHz"), ("power", r"Total on-chip power: ([\d.]+) W")):
            m = re.search(pat, t)
            if m:
                rep[key] = float(m.group(1))
        for blk in ("picorv32", "matmul_accel"):
            m = re.search(r"^\s*\S+\s+" + blk + r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", t, re.M)
            if m:
                rep[blk] = list(map(int, m.groups()))
        rep["file"] = str(f)
        out[name] = rep
    return out


# ---------------------------------------------------------------- one run
def run_program(code, mode, max_clocks=3000000, logfn=None):
    logfn = log_to(logfn)
    d = new_run_dir(code)
    res = {"run": d.name, "mode": mode, "time": time.strftime("%Y-%m-%d %H:%M:%S"), "mhz": MHZ}
    try:
        res["build"] = build(d, logfn)
        res["results"] = simulate(d, max_clocks, logfn) if mode == "sim" else board(d, logfn)
        res["fpga"] = fpga_reports()
        a, c = res["results"].get("accel"), res["results"].get("cpu")
        if a and c:
            res["speedup"] = c["total_cycles"] / a["total_cycles"] if a["total_cycles"] else None
            res["same_result"] = a["result"] == c["result"]
            logfn(f"done: speed-up {res['speedup']:.2f}x, results "
                  f"{'match' if res['same_result'] else 'DIFFER'}")
    except (RunError, subprocess.TimeoutExpired) as e:
        res["error"] = str(e)
        logfn("ERROR: " + str(e))
    (d / "results.json").write_text(json.dumps(res, indent=1))
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("action", choices=["build", "sim", "board", "mmi"])
    ap.add_argument("source", nargs="?")
    ap.add_argument("--max-clocks", type=int, default=3000000)
    a = ap.parse_args(argv)
    if a.action == "mmi":
        ensure_mmi()
        return
    if not a.source:
        ap.error("give the .c file")
    code = Path(a.source).read_text()
    if a.action == "build":
        d = new_run_dir(code)
        build(d)
        print(d)
        return
    res = run_program(code, a.action, a.max_clocks)
    print(json.dumps({k: v for k, v in res.items() if k != "fpga"}, indent=1))
    sys.exit(1 if "error" in res else 0)


if __name__ == "__main__":
    main()
