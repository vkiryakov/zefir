#!/usr/bin/env python3
"""The table of the openapi probe, from the results.tsv files of measure.sh:

    summarize.py <results.tsv>...

For every size: each variant's cold and warm build, the peak RSS of the
compiler, the binary and the document, and the increments of A and B over
the baseline of the same run (one runner per size). Then what the rule of
design 1.2, section 16, gives at the largest size with A, B and the
baseline: A if it costs at most ~10% more than B in cold time and in peak
memory; else B; STOP if the cheaper of them adds more than 30 s or 4 GB to
the cold build.
"""

import csv
import sys

NAMES = {
    "baseline": "baseline",
    "b": "B (model, JSON at startup)",
    "a": "A (JSON at compile time, pure functions)",
    "afill": "A (JSON at compile time, count + fill)",
    "acount": "count pass of A count + fill alone",
    "naive": "A naive (++ per piece)",
}


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def gb(kb):
    value = number(kb)
    return None if value is None else value / 1048576


def fmt(value, digits=1, sign=False):
    if value is None:
        return "–"
    return f"{value:+.{digits}f}" if sign else f"{value:.{digits}f}"


def main():
    rows = []
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as f:
            rows += list(csv.DictReader(f, delimiter="\t"))
    sizes = {}
    for row in rows:
        sizes.setdefault(int(row["routes"]), {})[row["variant"]] = row

    print("| routes | variant | cold, s | warm, s | peak RSS cold, GB | peak RSS warm, GB | binary, MB | document, KB | Δ cold s | Δ warm s | Δ RSS GB | JSON write, ms |")
    print("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for n in sorted(sizes):
        base = sizes[n].get("baseline")
        for variant in ["baseline", "b", "a", "afill", "acount", "naive"]:
            row = sizes[n].get(variant)
            if row is None:
                continue
            ok = row["cold_result"] == "ok"
            cold = number(row["cold_s"]) if ok else None
            warm = number(row["warm_s"]) if row["warm_result"] == "ok" else None
            rss = gb(row["cold_rss_kb"])
            rss_warm = gb(row["warm_rss_kb"])
            delta_cold = delta_warm = delta_rss = None
            if base is not None and variant != "baseline" and base["cold_result"] == "ok" and ok:
                delta_cold = cold - number(base["cold_s"])
                delta_rss = rss - gb(base["cold_rss_kb"])
                if warm is not None and base["warm_result"] == "ok":
                    delta_warm = warm - number(base["warm_s"])
            binary = number(row["bin_bytes"])
            document = number(row["doc_bytes"])
            write_ms = number(row["write_us_min"])
            cold_text = fmt(cold) if ok else row["cold_result"]
            warm_text = fmt(warm) if warm is not None else row["warm_result"]
            print(
                f"| {n} | {NAMES.get(variant, variant)} | {cold_text} | {warm_text} | {fmt(rss, 2)} | {fmt(rss_warm, 2)} | "
                f"{fmt(None if binary is None else binary / 1048576)} | {fmt(None if document is None else document / 1024, 0)} | "
                f"{fmt(delta_cold, 1, True)} | {fmt(delta_warm, 1, True)} | {fmt(delta_rss, 2, True)} | "
                f"{fmt(None if write_ms is None else write_ms / 1000, 2)} |"
            )

    full = [n for n in sorted(sizes) if all(v in sizes[n] for v in ("baseline", "a", "b"))]
    if not full:
        return
    n = full[-1]
    base, a, b = sizes[n]["baseline"], sizes[n]["a"], sizes[n]["b"]
    print()
    print(f"**The rule of section 16 at {n} routes.**")
    if base["cold_result"] != "ok":
        print(f"The baseline did not build: {base['cold_result']}.")
        return
    base_s, base_gb = number(base["cold_s"]), gb(base["cold_rss_kb"])
    within = {}
    for name, row in (("A", a), ("B", b)):
        if row["cold_result"] != "ok":
            print(f"- {name}: {row['cold_result']}.")
            continue
        added_s = number(row["cold_s"]) - base_s
        added_gb = gb(row["cold_rss_kb"]) - base_gb
        within[name] = added_s <= 30 and added_gb <= 4
        print(f"- {name} adds {added_s:+.1f} s and {added_gb:+.2f} GB to the cold build.")
    if not any(within.values()):
        print("- STOP: neither A nor B stays within +30 s and +4 GB of the cold build.")
        return
    if a["cold_result"] == "ok" and b["cold_result"] == "ok":
        ratio_s = number(a["cold_s"]) / number(b["cold_s"])
        ratio_gb = gb(a["cold_rss_kb"]) / gb(b["cold_rss_kb"])
        print(f"- A / B, cold build: {ratio_s:.3f} in time, {ratio_gb:.3f} in peak memory.")
        pick = "A" if ratio_s <= 1.10 and ratio_gb <= 1.10 else "B"
        print(f"- The rule gives {pick}.")
    else:
        print("- The rule gives " + ("A" if a["cold_result"] == "ok" else "B") + ": the other did not build.")


if __name__ == "__main__":
    main()
