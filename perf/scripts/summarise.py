#!/usr/bin/env python3
"""Summarise every result directory of one RUN_ID into summary.md / summary.csv.

Client-side results (k6 summary.json, vault-benchmark result.json) are
normalised to milliseconds and combined across load generators:
  * throughput is summed across nodes,
  * latency is reported per node plus the worst node (percentiles can't be
    merged exactly without raw samples) and a request-weighted mean.
Server-side results come from the Grafana export (grafana/stats.json): every
dashboard query, reported as baseline / steady / cooldown means (max across
series, e.g. across instances) and the steady-state max.

Usage: summarise.py <dir-containing-run-dirs> <RUN_ID> <out-dir>
"""
import csv
import glob
import json
import os
import sys


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def k6_row(d, params):
    s = load(os.path.join(d, "summary.json"))
    if not s:
        return None
    m = s.get("metrics", {})
    # Primary latency metric per script.
    for key in ("leaf_ready_ms", "http_req_duration{name:leaf}", "http_req_duration{name:sign}",
                "http_req_duration{name:kv_write}", "http_req_duration"):
        if key in m:
            lat_key = key
            break
    else:
        return None
    lat = m[lat_key]["values"]
    if params.get("script", "").startswith("consul-register-burst"):
        reqs = m.get("sidecars_registered", {}).get("values", {})
    else:
        reqs = m.get("http_reqs", {}).get("values", {})
    checks = m.get("checks", {}).get("values", {})
    return {
        "tool": "k6", "test": params.get("script", "").replace(".js", ""), "run": params.get("run_id"),
        "node": params.get("node"),
        "metric": lat_key, "requests": reqs.get("count"), "rate_per_s": reqs.get("rate"),
        "success_pct": 100 * checks["rate"] if "rate" in checks else None,
        "mean_ms": lat.get("avg"), "p50_ms": lat.get("med"), "p95_ms": lat.get("p(95)"),
        "p99_ms": lat.get("p(99)"), "max_ms": lat.get("max"),
    }


def vb_row(d, params):
    r = load(os.path.join(d, "result.json"))
    if not r:
        return None
    t = r.get("metrics", {}).get("total") or next(iter(r.get("metrics", {}).values()), None)
    if not t:
        return None
    lat = {k: v / 1e6 for k, v in t.get("latencies", {}).items() if isinstance(v, (int, float))}  # ns -> ms
    return {
        "tool": "vault-benchmark", "test": params.get("test", "").replace(".hcl", ""), "run": params.get("run_id"),
        "node": params.get("node"),
        "metric": "latencies", "requests": t.get("requests"), "rate_per_s": t.get("throughput", t.get("rate")),
        "success_pct": 100 * t["success"] if "success" in t else None,
        "mean_ms": lat.get("mean"), "p50_ms": lat.get("50th"), "p95_ms": lat.get("95th"),
        "p99_ms": lat.get("99th"), "max_ms": lat.get("max"),
    }


def f(v, nd=1):
    if v is None:
        return "-"
    return f"{v:,.{nd}f}" if isinstance(v, (int, float)) else str(v)


def main():
    root, run_id, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    rows, exports = [], []
    for d in sorted(glob.glob(os.path.join(root, f"{run_id}-*"))):
        if d.endswith("-summary"):
            continue
        params = load(os.path.join(d, "params.json")) or {}
        row = k6_row(d, params) if params.get("tool") == "k6" else vb_row(d, params)
        if row:
            rows.append(row)
        st = load(os.path.join(d, "grafana", "stats.json"))
        if st:
            exports.append((os.path.basename(d), st))

    cols = ["tool", "test", "run", "node", "requests", "rate_per_s", "success_pct", "mean_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms"]
    with open(os.path.join(out, "summary.csv"), "w", newline="") as fc:
        w = csv.DictWriter(fc, fieldnames=cols + ["metric"])
        w.writeheader()
        for r in rows:
            w.writerow(r)

    md = [f"# Run {run_id}\n"]
    md.append("## Client-side results (ms)\n")
    md.append("| Tool | Test | Run | Node | Requests | Rate/s | Success % | Mean | p50 | p95 | p99 | Max |")
    md.append("|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    groups = {}
    for r in rows:
        md.append(f"| {r['tool']} | {r['test']} | {r['run']} | {r['node']} | {f(r['requests'], 0)} | {f(r['rate_per_s'])} | "
                  f"{f(r['success_pct'], 2)} | {f(r['mean_ms'], 2)} | {f(r['p50_ms'], 2)} | {f(r['p95_ms'], 2)} | "
                  f"{f(r['p99_ms'], 2)} | {f(r['max_ms'], 2)} |")
        # Combine load generators for the same run (not the steps of a chained run).
        groups.setdefault((r["tool"], r["test"], r["run"]), []).append(r)
    for (tool, test, run), rs in groups.items():
        if len(rs) < 2:
            continue
        n = sum(r["requests"] or 0 for r in rs)
        wmean = sum((r["mean_ms"] or 0) * (r["requests"] or 0) for r in rs) / n if n else None
        worst = lambda k: max((r[k] for r in rs if r[k] is not None), default=None)
        md.append(f"| **{tool}** | **{test}** | **{run}** | **all ({len(rs)})** | **{f(n, 0)}** | "
                  f"**{f(sum(r['rate_per_s'] or 0 for r in rs))}** | - | **{f(wmean, 2)}** | - | "
                  f"worst {f(worst('p95_ms'), 2)} | worst {f(worst('p99_ms'), 2)} | worst {f(worst('max_ms'), 2)} |")
    md.append("\nk6 rates cover the whole k6 run (ramp + hold); vault-benchmark covers the measured run only. "
              "Combined rows sum throughput and report the worst node's percentiles.\n")

    for name, st in exports:
        phases = [p["name"] for p in st.get("phases", [])]
        md.append(f"## Server-side (Grafana export from `{name}`)\n")
        md.append("Mean per phase (max across series, e.g. across instances), plus the max across all steady "
                  "phases (chained runs have one per step). "
                  "Full per-series detail, PNGs and CSV are in that directory's `grafana/`.\n")
        md.append("| Panel | Query | Unit | " + " | ".join(phases) + " | steady max |")
        md.append("|---|---|---|" + "---:|" * len(phases) + "---:|")
        by_query = {}
        for p in st.get("panels", []):
            for s in p.get("series", []):
                if "phases" not in s:
                    continue
                by_query.setdefault((p["title"], s["expr"], p.get("unit", "")), []).append(s)
        for (title, expr, unit), series in by_query.items():
            def agg(phase, stat):
                vals = [(s["phases"].get(phase) or {}).get(stat) for s in series]
                vals = [v for v in vals if v is not None]
                return max(vals) if vals else None
            label = series[0]["series"] if len(series) == 1 else f"{len(series)} series"
            smaxes = [agg(ph, 'max') for ph in phases if ph.startswith('steady')]
            smaxes = [v for v in smaxes if v is not None]
            md.append(f"| {title} | {label} | {unit} | " + " | ".join(f(agg(ph, 'mean'), 3) for ph in phases)
                      + f" | {f(max(smaxes) if smaxes else None, 3)} |")
        md.append("")

    open(os.path.join(out, "summary.md"), "w").write("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
