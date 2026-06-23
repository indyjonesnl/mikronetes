#!/usr/bin/env python3
"""Aggregate mem-sampler.sh CSV into an avg/peak-per-node Markdown table.

Input CSV lines: EPOCH,NAME,USED  (USED like "217.3MiB", "1.2GiB", "0B").
Output: a Markdown table (avg, peak, peak-as-%-of-512MiB, sample count) per node.
Always exits 0 — it must never change the smoke test's own pass/fail.
"""
import sys

CAP_BYTES = 512 * 1024 * 1024  # the 512 MiB per-node budget

_UNITS = {
    "B": 1,
    "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4,
    "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4,
}


def parse_bytes(s):
    """'217.3MiB' -> bytes (int). Returns None if unparseable."""
    s = s.strip()
    if not s:
        return None
    num = s
    unit = "B"
    for i, ch in enumerate(s):
        if ch.isalpha() or ch == "%":
            num, unit = s[:i], s[i:]
            break
    try:
        value = float(num)
    except ValueError:
        return None
    mult = _UNITS.get(unit.upper().strip())
    if mult is None:
        return None
    return int(value * mult)


def aggregate(rows):
    """rows: iterable of (name, used_bytes). -> {name: {avg, peak, count}} sorted."""
    by_node = {}
    for name, b in rows:
        by_node.setdefault(name, []).append(b)
    out = {}
    for name in sorted(by_node):
        vals = by_node[name]
        out[name] = {
            "avg": sum(vals) // len(vals),
            "peak": max(vals),
            "count": len(vals),
        }
    return out


def _mib(b):
    return f"{b / 1024 / 1024:.1f} MiB"


def render(stats):
    if not stats:
        return "_no memory samples collected_"
    lines = [
        "| Node | Avg | Peak | Peak % of 512 MiB | Samples |",
        "|------|-----|------|-------------------|---------|",
    ]
    for name, s in stats.items():
        pct = s["peak"] / CAP_BYTES * 100
        lines.append(
            f"| {name} | {_mib(s['avg'])} | {_mib(s['peak'])} | {pct:.0f}% | {s['count']} |"
        )
    return "\n".join(lines)


def read_rows(path):
    rows = []
    try:
        with open(path) as f:
            for line in f:
                parts = line.strip().split(",")
                if len(parts) != 3:
                    continue
                b = parse_bytes(parts[2])
                if b is not None:
                    rows.append((parts[1], b))
    except FileNotFoundError:
        pass
    return rows


def main(argv):
    path = argv[1] if len(argv) > 1 else "mem-samples.csv"
    print(render(aggregate(read_rows(path))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
