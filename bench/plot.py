#!/usr/bin/env python3
"""Render clickzig benchmark results to assets/benchmarks.svg.

Usage:
    python3 bench/plot.py RESULTS_JSON [OUT_SVG]

RESULTS_JSON is produced by bench/collect.py (merged clickzig runs plus
the clickhouse-client reference). No third-party dependencies: the SVG
is written by hand so it stays small, crisp, and theme-aware (it follows
the viewer's light/dark preference via prefers-color-scheme).
"""

import json
import sys
from html import escape

W = 880
PAD = 32

LIGHT = {
    "surface": "#fcfcfb",
    "text1": "#0b0b0b",
    "text2": "#52514e",
    "text3": "#6f6e69",
    "grid": "#e4e3df",
    "axis": "#c9c8c2",
    "s1": "#2a78d6",
    "s2": "#eb6834",
    "tile": "#f4f3f0",
}
DARK = {
    "surface": "#1a1a19",
    "text1": "#f0efec",
    "text2": "#c3c2b7",
    "text3": "#9a998f",
    "grid": "#2c2c2a",
    "axis": "#45453f",
    "s1": "#3987e5",
    "s2": "#d95926",
    "tile": "#242423",
}

READ_ROWS = [
    ("read_uint64", "UInt64 scan", "20M rows"),
    ("read_uint64_lz4", "UInt64 scan + LZ4", "20M rows"),
    ("read_string", "String scan", "5M rows"),
    ("read_string_lz4", "String scan + LZ4", "5M rows"),
]


def css():
    def block(p):
        return "".join(
            f"--{k}:{v};" for k, v in p.items()
        )

    return f"""
svg {{ {block(LIGHT)} font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }}
@media (prefers-color-scheme: dark) {{ svg {{ {block(DARK)} }} }}
.bg {{ fill: var(--surface); }}
.t1 {{ fill: var(--text1); }}
.t2 {{ fill: var(--text2); }}
.t3 {{ fill: var(--text3); }}
.grid {{ stroke: var(--grid); stroke-width: 1; }}
.axis {{ stroke: var(--axis); stroke-width: 1; }}
.s1 {{ fill: var(--s1); }}
.s2 {{ fill: var(--s2); }}
.tile {{ fill: var(--tile); }}
.h1 {{ font-size: 20px; font-weight: 650; }}
.h2 {{ font-size: 14px; font-weight: 600; }}
.sm {{ font-size: 12px; }}
.xs {{ font-size: 11px; }}
.num {{ font-variant-numeric: tabular-nums; }}
.big {{ font-size: 26px; font-weight: 650; }}
"""


def hbar(x, y, w, h, cls, r=4):
    """Horizontal bar anchored at x, rounded only at the data end."""
    w = max(w, r + 1)
    return (
        f'<path class="{cls}" d="M{x:.1f},{y:.1f} h{w - r:.1f} '
        f"a{r},{r} 0 0 1 {r},{r} v{h - 2 * r:.1f} a{r},{r} 0 0 1 -{r},{r} "
        f'h-{w - r:.1f} z"/>'
    )


def vbar(x, base, w, h, cls, r=4):
    """Vertical bar anchored at the baseline, rounded only at the top."""
    h = max(h, r + 1)
    y = base - h
    return (
        f'<path class="{cls}" d="M{x:.1f},{base:.1f} v-{h - r:.1f} '
        f"a{r},{r} 0 0 1 {r},-{r} h{w - 2 * r:.1f} a{r},{r} 0 0 1 {r},{r} "
        f'v{h - r:.1f} z"/>'
    )


def text(x, y, s, cls, anchor="start"):
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}">{escape(s)}</text>'


def nice_max(v, step):
    return step * (int(v / step) + 1)


def render(res):
    out = []
    y = PAD

    out.append(text(PAD, y + 18, "clickzig benchmarks", "t1 h1"))
    out.append(text(PAD, y + 40, res["environment"], "t2 sm"))
    y += 64

    # ---- Panel A: read throughput --------------------------------------
    out.append(text(PAD, y + 14, "Read throughput — million rows/s (higher is better)", "t1 h2"))
    # legend
    lx = W - PAD
    items = [("clickhouse-client 26.3 (C++)", "s2"), ("clickzig", "s1")]
    for label, cls in items:
        tw = 7.0 * len(label)
        lx -= tw
        out.append(text(lx, y + 14, label, "t2 sm"))
        lx -= 16
        out.append(f'<rect class="{cls}" x="{lx:.1f}" y="{y + 4:.1f}" width="12" height="12" rx="3"/>')
        lx -= 18
    y += 30

    label_w = 170
    plot_x = PAD + label_w
    plot_w = W - PAD - plot_x - 56
    vmax = max(
        max(res["clickzig"][k]["rows_per_s"], res["reference"].get(k, {}).get("rows_per_s", 0))
        for k, _, _ in READ_ROWS
    ) / 1e6
    xmax = nice_max(vmax, 100)
    bar_h = 14
    group_h = bar_h * 2 + 2 + 18
    plot_h = group_h * len(READ_ROWS)

    for tick in range(0, xmax + 1, 100):
        gx = plot_x + plot_w * tick / xmax
        out.append(f'<line class="grid" x1="{gx:.1f}" y1="{y - 4:.1f}" x2="{gx:.1f}" y2="{y + plot_h - 10:.1f}"/>')
        out.append(text(gx, y + plot_h + 4, f"{tick}", "t3 xs num", "middle"))

    for i, (key, name, sub) in enumerate(READ_ROWS):
        gy = y + i * group_h
        out.append(text(PAD, gy + 13, name, "t1 sm"))
        out.append(text(PAD, gy + 28, sub, "t3 xs"))
        cz = res["clickzig"][key]["rows_per_s"] / 1e6
        ref = res["reference"].get(key, {}).get("rows_per_s", 0) / 1e6
        for j, (v, cls) in enumerate([(cz, "s1"), (ref, "s2")]):
            by = gy + j * (bar_h + 2)
            bw = plot_w * v / xmax
            out.append(hbar(plot_x, by, bw, bar_h, cls))
            out.append(text(plot_x + bw + 6, by + bar_h - 3, f"{v:,.0f}", "t2 xs num"))
    out.append(f'<line class="axis" x1="{plot_x:.1f}" y1="{y - 4:.1f}" x2="{plot_x:.1f}" y2="{y + plot_h - 10:.1f}"/>')
    y += plot_h + 26

    # ---- Panel B: concurrency + Panel C: tiles --------------------------
    col_w = (W - 2 * PAD - 32) / 2
    bx = PAD
    out.append(text(bx, y + 14, "Concurrent queries over a Pool — queries/s", "t1 h2"))
    out.append(text(bx, y + 32, "48 × SELECT 500k rows (UInt64 + String), Io.Group workers", "t3 xs"))
    cy = y + 48
    conc = res["concurrency"]
    cmax = nice_max(max(c["queries_per_s"] for c in conc), 100)
    ch = 150
    base = cy + ch
    for tick in range(0, cmax + 1, 100):
        gy = base - ch * tick / cmax
        out.append(f'<line class="grid" x1="{bx + 28:.1f}" y1="{gy:.1f}" x2="{bx + col_w:.1f}" y2="{gy:.1f}"/>')
        out.append(text(bx + 22, gy + 4, f"{tick}", "t3 xs num", "end"))
    n = len(conc)
    slot = (col_w - 36) / n
    bw = min(44, slot - 10)
    for i, c in enumerate(conc):
        x0 = bx + 36 + i * slot + (slot - bw) / 2
        h = ch * c["queries_per_s"] / cmax
        out.append(vbar(x0, base, bw, h, "s1"))
        out.append(text(x0 + bw / 2, base - h - 6, f"{c['queries_per_s']:.0f}", "t2 xs num", "middle"))
        out.append(text(x0 + bw / 2, base + 16, f"{c['concurrency']}", "t2 xs num", "middle"))
    out.append(f'<line class="axis" x1="{bx + 28:.1f}" y1="{base:.1f}" x2="{bx + col_w:.1f}" y2="{base:.1f}"/>')
    out.append(text(bx + 36 + (col_w - 36) / 2, base + 32, "workers (connections)", "t3 xs", "middle"))

    tx = PAD + col_w + 32
    tw = col_w
    th = 92
    tiles = [
        (
            "Ping round trip (p50)",
            f"{res['ping']['p50_ns'] / 1000:.0f} µs",
            f"p99 {res['ping']['p99_ns'] / 1000:.0f} µs · 20k sequential pings",
        ),
        (
            "INSERT, 100k rows × 3 columns",
            f"{res['clickzig']['insert_none']['rows_per_s'] / 1e6:.2f}M rows/s",
            f"clickhouse-client: {res['reference']['insert_none']['rows_per_s'] / 1e6:.2f}M rows/s · server-bound",
        ),
    ]
    for i, (title, big, sub) in enumerate(tiles):
        ty = y + 8 + i * (th + 14)
        out.append(f'<rect class="tile" x="{tx:.1f}" y="{ty:.1f}" width="{tw:.1f}" height="{th}" rx="10"/>')
        out.append(text(tx + 16, ty + 24, title, "t2 sm"))
        out.append(text(tx + 16, ty + 58, big, "t1 big num"))
        out.append(text(tx + 16, ty + 80, sub, "t3 xs"))
    y = max(base + 40, y + 8 + 2 * th + 14) + 18

    for line in res["notes"]:
        out.append(text(PAD, y, line, "t3 xs"))
        y += 16
    y += PAD - 12

    title = "clickzig benchmarks"
    desc = "; ".join(
        f"{name}: clickzig {res['clickzig'][k]['rows_per_s'] / 1e6:.0f}M rows/s vs clickhouse-client "
        f"{res['reference'].get(k, {}).get('rows_per_s', 0) / 1e6:.0f}M rows/s"
        for k, name, _ in READ_ROWS
    )
    head = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {y:.0f}" width="{W}" height="{y:.0f}" '
        f'role="img" aria-labelledby="t d">'
        f'<title id="t">{escape(title)}</title><desc id="d">{escape(desc)}</desc>'
        f"<style>{css()}</style>"
        f'<rect class="bg" x="0" y="0" width="{W}" height="{y:.0f}" rx="12"/>'
    )
    return head + "".join(out) + "</svg>\n"


def main():
    res = json.load(open(sys.argv[1]))
    out = sys.argv[2] if len(sys.argv) > 2 else "assets/benchmarks.svg"
    with open(out, "w") as f:
        f.write(render(res))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
