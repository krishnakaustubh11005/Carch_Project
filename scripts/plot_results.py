#!/usr/bin/env python3
"""Chart the board jobs recorded by fpga/run.tcl (fpga/out/results.csv).

    python3 scripts/plot_results.py fpga/out/results.csv  [-o results.html] [--mhz 50]

Writes an HTML page (no extra packages needed) with
  1. software vs accelerator cycles for every job (log scale),
  2. speed-up for every job,
  3. the table of all jobs.
Jobs are ordered by the work they do (M*K*N multiply-adds). When the same
M x K x N appears more than once, the latest PASS row is used.
"""
import argparse
import csv
import html
import math
from pathlib import Path

SW, ACC, SPD = "#c0632b", "#1f7a6d", "#5b4fb3"


def load(path):
    rows = [r for r in csv.DictReader(open(path)) if r.get("sw_cycles")]
    latest = {}
    for r in rows:
        key = (int(r["m"]), int(r["k"]), int(r["n"]))
        if r["result"] == "PASS" or key not in latest:
            latest[key] = r
    return sorted(latest.items(), key=lambda kv: (kv[0][0] * kv[0][1] * kv[0][2], kv[0])), rows


def bars_svg(jobs, mhz):
    w, h, left, bottom, top = 900, 360, 70, 70, 20
    vals = [int(r[c]) for _, r in jobs for c in ("sw_cycles", "accel_cycles")]
    lo = 10 ** math.floor(math.log10(max(1, min(vals))))
    hi = 10 ** math.ceil(math.log10(max(vals)))
    def y(v):
        return top + (h - top - bottom) * (1 - (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)))
    slot = (w - left - 20) / max(1, len(jobs))
    bw = min(28, slot * 0.36)
    out = [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="cycles per job">']
    d = lo
    while d <= hi:
        out.append(f'<line x1="{left}" x2="{w-20}" y1="{y(d):.1f}" y2="{y(d):.1f}" class="grid"/>')
        out.append(f'<text x="{left-8}" y="{y(d)+4:.1f}" text-anchor="end" class="tick">{d:,}</text>')
        d *= 10
    for i, ((m, k, n), r) in enumerate(jobs):
        cx = left + slot * (i + 0.5)
        for j, (col, color) in enumerate((("sw_cycles", SW), ("accel_cycles", ACC))):
            v = int(r[col])
            x = cx - bw - 1 if j == 0 else cx + 1
            out.append(f'<rect x="{x:.1f}" y="{y(v):.1f}" width="{bw:.1f}" height="{h-bottom-y(v):.1f}" fill="{color}">'
                       f'<title>{m}x{k}x{n} {"software" if j == 0 else "accelerator"}: {v:,} cycles '
                       f'({v / mhz:,.1f} us)</title></rect>')
        out.append(f'<text x="{cx:.1f}" y="{h-bottom+16}" text-anchor="middle" class="tick">{m}x{k}x{n}</text>')
    out.append(f'<text x="{left}" y="{h-12}" class="axis">job (M x K x N), ordered by multiply-adds</text>')
    out.append(f'<text x="14" y="{top+8}" class="axis" transform="rotate(-90 14 {top+8})" text-anchor="end">cycles (log)</text>')
    out.append("</svg>")
    return "\n".join(out)


def speed_svg(jobs):
    w, h, left, bottom, top = 900, 300, 70, 70, 24
    speeds = [float(r["speedup"]) for _, r in jobs]
    hi = max(1.0, max(speeds)) * 1.12
    slot = (w - left - 20) / max(1, len(jobs))
    bw = min(40, slot * 0.6)
    def y(v):
        return top + (h - top - bottom) * (1 - v / hi)
    out = [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="speed-up per job">']
    raw = hi / 5
    mag = 10 ** math.floor(math.log10(raw))
    step = next(s * mag for s in (1, 2, 5, 10) if s * mag >= raw)
    v = 0.0
    while v <= hi:
        out.append(f'<line x1="{left}" x2="{w-20}" y1="{y(v):.1f}" y2="{y(v):.1f}" class="grid"/>')
        out.append(f'<text x="{left-8}" y="{y(v)+4:.1f}" text-anchor="end" class="tick">{v:g}x</text>')
        v += step
    for i, ((m, k, n), r) in enumerate(jobs):
        s = float(r["speedup"])
        cx = left + slot * (i + 0.5)
        out.append(f'<rect x="{cx-bw/2:.1f}" y="{y(s):.1f}" width="{bw:.1f}" height="{h-bottom-y(s):.1f}" fill="{SPD}">'
                   f'<title>{m}x{k}x{n}: {s:.1f}x</title></rect>')
        out.append(f'<text x="{cx:.1f}" y="{y(s)-5:.1f}" text-anchor="middle" class="val">{s:.1f}x</text>')
        out.append(f'<text x="{cx:.1f}" y="{h-bottom+16}" text-anchor="middle" class="tick">{m}x{k}x{n}</text>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("-o", "--output")
    ap.add_argument("--mhz", type=float, default=50.0, help="clock of the board build (default 50)")
    a = ap.parse_args()
    jobs, rows = load(a.csv)
    if not jobs:
        raise SystemExit("no completed jobs in " + a.csv)
    out = Path(a.output or Path(a.csv).with_suffix(".html"))
    table = "".join(
        f"<tr><td>{html.escape(r['job'])}</td><td>{html.escape(r['time'])}</td><td>{r['m']}x{r['k']}x{r['n']}</td>"
        f"<td>{html.escape(r['data'])} {html.escape(r['seed'])}</td><td class=n>{int(r['sw_cycles']):,}</td>"
        f"<td class=n>{int(r['accel_cycles']):,}</td><td class=n>{int(r['fetch_cycles']):,}</td>"
        f"<td class=n>{int(r['compute_cycles']):,}</td><td class=n>{float(r['speedup']):.1f}x</td>"
        f"<td>{html.escape(r['result'])}</td></tr>" for r in rows)
    best = max(jobs, key=lambda kv: float(kv[1]["speedup"]))
    page = f"""<!doctype html><meta charset="utf-8"><title>Carch Board Results</title>
<style>
:root{{--bg:#fbfcfc;--fg:#1c2421;--muted:#5d6a65;--grid:#dfe6e3}}
@media (prefers-color-scheme:dark){{:root{{--bg:#121816;--fg:#e2e9e6;--muted:#93a29c;--grid:#2c3632}}}}
body{{background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,"Segoe UI",sans-serif;max-width:960px;margin:0 auto;padding:24px 16px}}
h1{{margin:0 0 4px}} p{{color:var(--muted);margin:0 0 18px}} h2{{margin:28px 0 6px;font-size:1.1rem}}
svg{{width:100%;height:auto}} .grid{{stroke:var(--grid)}} .tick,.axis,.val{{fill:var(--muted);font-size:12px}}
.val{{fill:var(--fg)}} .key span{{display:inline-block;width:12px;height:12px;margin:0 6px 0 14px;vertical-align:-1px}}
table{{border-collapse:collapse;width:100%;font-size:13px}} th,td{{padding:4px 8px;border-bottom:1px solid var(--grid);text-align:left}}
td.n{{text-align:right;font-variant-numeric:tabular-nums}} .wrap{{overflow-x:auto}}
</style>
<h1>Carch on the PYNQ-Z2</h1>
<p>{len(rows)} jobs measured on the board at {a.mhz:g} MHz. Software = the same matmul on the PicoRV32 (RV32IM).
Best speed-up: {float(best[1]['speedup']):.1f}x for {best[0][0]}x{best[0][1]}x{best[0][2]}.</p>
<h2>Cycles per job</h2><div class="key"><span style="background:{SW}"></span>software<span style="background:{ACC}"></span>accelerator (end to end)</div>
{bars_svg(jobs, a.mhz)}
<h2>Speed-up</h2>
{speed_svg(jobs)}
<h2>All jobs</h2><div class="wrap"><table><tr><th>job</th><th>time</th><th>M x K x N</th><th>data</th><th>software</th>
<th>accelerator</th><th>fetch</th><th>compute</th><th>speed-up</th><th>result</th></tr>{table}</table></div>
"""
    out.write_text(page)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
