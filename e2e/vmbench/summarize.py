#!/usr/bin/env python3
"""Summarizes benchmark results: the median of each measurement per label,
and how the second label compares with the first.

    summarize.py <baseline.jsonl> <candidate.jsonl> [more.jsonl ...]

Prints a Markdown table. "Change" is candidate vs baseline, worded so that
positive always means slower or more (time, latency, memory) or fewer
(throughput), so a reader never has to know which direction is good.
"""
import json
import re
import statistics
import sys

# Units where a bigger number is better.
HIGHER_IS_BETTER = {"eps", "iops", "MiB/s"}


def load(path):
    label, values = None, {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            # bc prints fractions without the leading zero (.52).
            row = json.loads(re.sub(r'":(-?)\.', r'":\g<1>0.', line))
            label = row.get("label", label)
            values.setdefault(row["name"], (row["unit"], []))[1].append(float(row["value"]))
    return label, {name: (unit, statistics.median(v), len(v)) for name, (unit, v) in values.items()}


def change(unit, base, cand):
    if base == 0:
        return "n/a"
    ratio = cand / base
    if unit in HIGHER_IS_BETTER:
        pct = (1 / ratio - 1) * 100 if ratio else float("inf")
        word = "slower" if pct > 0 else "faster"
    elif unit == "MB":
        pct = (ratio - 1) * 100
        word = "more" if pct > 0 else "less"
    else:
        pct = (ratio - 1) * 100
        word = "slower" if pct > 0 else "faster"
    if abs(pct) < 3:
        return "same"
    return f"{abs(pct):.0f}% {word} ({ratio:.2f}x)"


def fmt(v):
    return f"{v:,.0f}" if abs(v) >= 100 else f"{v:.3g}"


def main(paths):
    runs = [load(p) for p in paths]
    base_label, base = runs[0]
    names = sorted({n for _, r in runs for n in r})
    header = ["measurement", "unit"] + [label for label, _ in runs] + [f"{label} vs {base_label}" for label, _ in runs[1:]]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for name in names:
        unit = next(r[name][0] for _, r in runs if name in r)
        cells = [name, unit]
        for _, r in runs:
            cells.append(fmt(r[name][1]) if name in r else "")
        for _, r in runs[1:]:
            cells.append(change(unit, base[name][1], r[name][1]) if name in r and name in base else "")
        print("| " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
