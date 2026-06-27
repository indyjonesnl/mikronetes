#!/usr/bin/env python3
"""Unit checks for mem-report.py (no docker needed). Run: python3 scripts/test_mem_report.py"""
import importlib.util
import os

spec = importlib.util.spec_from_file_location(
    "mem_report", os.path.join(os.path.dirname(__file__), "mem-report.py")
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def check(label, got, want):
    assert got == want, f"{label}: got {got!r}, want {want!r}"
    print(f"ok: {label}")


# parse_bytes units
check("MiB", m.parse_bytes("217.3MiB"), int(217.3 * 1024**2))
check("GiB", m.parse_bytes("1.5GiB"), int(1.5 * 1024**3))
check("plain B", m.parse_bytes("0B"), 0)
check("KiB", m.parse_bytes("512KiB"), 512 * 1024)
check("bad", m.parse_bytes("n/a"), None)
check("empty", m.parse_bytes(""), None)

# aggregate avg/peak/count over two nodes
rows = [
    ("worker1", 100 * 1024**2),
    ("worker1", 300 * 1024**2),  # peak
    ("worker1", 200 * 1024**2),
    ("controller", 450 * 1024**2),
]
stats = m.aggregate(rows)
check("w1 avg", stats["worker1"]["avg"], 200 * 1024**2)
check("w1 peak", stats["worker1"]["peak"], 300 * 1024**2)
check("w1 count", stats["worker1"]["count"], 3)
check("ctrl peak", stats["controller"]["peak"], 450 * 1024**2)
# sorted: controller before worker1
check("order", list(stats.keys()), ["controller", "worker1"])

# render: table contains peak % of 512MiB (300/512 = 59%, 450/512 = 88%)
table = m.render(stats)
assert "Peak % of 512 MiB" in table, table
assert "59%" in table, table
assert "88%" in table, table
print("ok: render table")

# empty -> graceful
check("empty render", m.render(m.aggregate([])), "_no memory samples collected_")

print("ALL PASSED")
