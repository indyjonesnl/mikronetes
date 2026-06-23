#!/usr/bin/env python3
"""Aggregate mem-breakdown.sh raw lines into a per-component PSS table.

Raw line: CONTAINER:<name> PSS:<kb> BASE:<argv0-basename>
Output: components ranked by total PSS (MiB) across the cluster — the biggest RAM
users to focus on — plus process count and which nodes they ran on.
Always exits 0.
"""
import sys

# Collapse noisy argv0 basenames into stable component labels.
RENAME = {
    "containerd-shim-runc-v2": "containerd-shim",
    "kube-controller-manage": "kube-controller-manager",  # /proc cmdline is full, but guard anyway
}


def label(base):
    return RENAME.get(base, base)


def main(argv):
    path = argv[1] if len(argv) > 1 else "mem-breakdown-raw.txt"
    comps = {}  # label -> {pss_kb, procs, nodes:set}
    total = 0
    try:
        with open(path) as f:
            for line in f:
                node = pss = base = None
                for tok in line.split():
                    if tok.startswith("CONTAINER:"):
                        node = tok[len("CONTAINER:"):]
                        # Strip noisy cluster prefixes so node labels stay short.
                        for pfx in ("mikronetes-", "rusternetes-cdrsf-", "rusternetes-"):
                            if node.startswith(pfx):
                                node = node[len(pfx):]
                                break
                    elif tok.startswith("PSS:"):
                        try:
                            pss = int(tok[len("PSS:"):])
                        except ValueError:
                            pss = None
                    elif tok.startswith("BASE:"):
                        base = tok[len("BASE:"):]
                if base is None or pss is None:
                    continue
                lbl = label(base)
                c = comps.setdefault(lbl, {"pss": 0, "procs": 0, "nodes": set()})
                c["pss"] += pss
                c["procs"] += 1
                if node:
                    c["nodes"].add(node)
                total += pss
    except FileNotFoundError:
        print("_no breakdown data_")
        return 0

    if not comps:
        print("_no breakdown data_")
        return 0

    rows = sorted(comps.items(), key=lambda kv: kv[1]["pss"], reverse=True)
    print("| Component | PSS (MiB) | % of total | procs | nodes |")
    print("|-----------|-----------|-----------|-------|-------|")
    for lbl, c in rows:
        mib = c["pss"] / 1024
        pct = c["pss"] / total * 100 if total else 0
        nodes = ",".join(sorted(c["nodes"]))
        print(f"| {lbl} | {mib:.1f} | {pct:.0f}% | {c['procs']} | {nodes} |")
    print(f"| **TOTAL** | **{total/1024:.1f}** | 100% | | |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
