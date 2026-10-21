#!/usr/bin/env python3
"""The table of the openapi probe, from the results.tsv files of measure.sh:

    summarize.py <results.tsv>...

For every size: each variant's cold and warm build, the peak RSS of the
compiler, the binary and the document, and the increments of the real
generator over the baseline of the same run (one runner per size). Then
what the thresholds of design 1.2, section 16, say at the largest size:
STOP if the document adds more than 30 s or 4 GB to the cold build.
"""

import csv
import sys

NAMES = {
    "baseline": "baseline",
    "real": "zefir.openapi.document",
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
        for variant in ["baseline", "real"]:
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

    full = [n for n in sorted(sizes) if all(v in sizes[n] for v in ("baseline", "real"))]
    if not full:
        return
    n = full[-1]
    base, real = sizes[n]["baseline"], sizes[n]["real"]
    print()
    print(f"**The thresholds of section 16 at {n} routes.**")
    if base["cold_result"] != "ok":
        print(f"The baseline did not build: {base['cold_result']}.")
        return
    if real["cold_result"] != "ok":
        print(f"- STOP: the document did not build: {real['cold_result']}.")
        return
    added_s = number(real["cold_s"]) - number(base["cold_s"])
    added_gb = gb(real["cold_rss_kb"]) - gb(base["cold_rss_kb"])
    print(f"- The document adds {added_s:+.1f} s and {added_gb:+.2f} GB to the cold build.")
    if added_s > 30 or added_gb > 4:
        print("- STOP: more than +30 s or +4 GB.")
    else:
        print("- Within +30 s and +4 GB.")


if __name__ == "__main__":
    main()
