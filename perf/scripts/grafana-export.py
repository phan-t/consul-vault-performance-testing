#!/usr/bin/env python3
"""Export a Grafana dashboard for a test window.

Driven by the live dashboard definition, so every panel (and every query in
it) is exported - panels added to the dashboard later are picked up
automatically. For the window [--from, --to] it writes to --out:

  dashboard.png          full dashboard render (needs the image renderer)
  panels/NN-<title>.png  one render per panel
  metrics.csv            every panel query's time series (long format)
  stats.json / stats.md  per-series statistics for each phase
                         (baseline / warmup / steady / cooldown)
  dashboard.json         the dashboard definition that was exported
  links.txt              Grafana link for the same window

Usage:
  grafana-export.py --url http://monitoring.perf.internal:3000 --uid consul-vault-perf \
    --from <ms> --to <ms> --phases phases.json --out <dir> [--title "..."]
Credentials: GRAFANA_USER / GRAFANA_PASS environment variables.
"""
import argparse
import base64
import csv
import datetime
import json
import math
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PROM_DS = "prometheus"


class Grafana:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}"}

    def get(self, path, params=None, raw=False, timeout=120):
        q = f"?{urllib.parse.urlencode(params)}" if params else ""
        req = urllib.request.Request(f"{self.url}{path}{q}", headers=self.headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
        return body if raw else json.loads(body)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60]


def legend(fmt, labels, expr):
    if not fmt:
        return json.dumps(labels, sort_keys=True) if labels else expr
    return re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: labels.get(m.group(1), ""), fmt)


def phase_stats(points, start, end):
    vals = [v for t, v in points if start <= t < end and v is not None and not math.isnan(v)]
    if not vals:
        return None
    return {
        "count": len(vals),
        "mean": statistics.fmean(vals),
        "min": min(vals),
        "max": max(vals),
        "p50": statistics.median(vals),
        "last": vals[-1],
    }


def fmt(v):
    if v is None:
        return "-"
    return f"{v:.4g}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--uid", default="consul-vault-perf")
    ap.add_argument("--from", dest="start", type=int, required=True, help="epoch ms")
    ap.add_argument("--to", dest="end", type=int, required=True, help="epoch ms")
    ap.add_argument("--phases", required=True, help="JSON file: [{name, start, end}] in epoch ms")
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--public-url", default=os.environ.get("GRAFANA_PUBLIC_URL", ""))
    args = ap.parse_args()

    g = Grafana(args.url, os.environ.get("GRAFANA_USER", "admin"), os.environ["GRAFANA_PASS"])
    os.makedirs(os.path.join(args.out, "panels"), exist_ok=True)
    phases = json.load(open(args.phases))

    dash = g.get(f"/api/dashboards/uid/{args.uid}")["dashboard"]
    json.dump(dash, open(os.path.join(args.out, "dashboard.json"), "w"), indent=2)
    panels = [p for p in dash.get("panels", []) if p.get("type") != "row"]

    # --- Links --------------------------------------------------------------
    with open(os.path.join(args.out, "links.txt"), "w") as f:
        for base in filter(None, [args.url, args.public_url]):
            f.write(f"{base.rstrip('/')}/d/{args.uid}/?from={args.start}&to={args.end}&timezone=utc\n")

    # --- PNG renders (best effort) ------------------------------------------
    rendered, render_errors = 0, []
    rows = max((p["gridPos"]["y"] + p["gridPos"]["h"]) for p in dash["panels"])
    common = {"from": args.start, "to": args.end, "tz": "UTC", "theme": "light"}
    try:
        # ~46px per grid unit at 1800px wide (panel chrome + gutters), plus headroom.
        png = g.get(f"/render/d/{args.uid}/", {**common, "width": 1800, "height": rows * 46 + 320, "kiosk": "true"},
                    raw=True, timeout=300)
        open(os.path.join(args.out, "dashboard.png"), "wb").write(png)
        rendered += 1
    except (urllib.error.URLError, OSError) as e:
        render_errors.append(f"dashboard: {e}")

    def render_panel(item):
        i, p = item
        name = f"{i:02d}-{slug(p.get('title', 'panel'))}.png"
        for attempt in range(6):
            try:
                png = g.get(f"/render/d-solo/{args.uid}/", {**common, "panelId": p["id"], "width": 1000, "height": 500},
                            raw=True, timeout=180)
                open(os.path.join(args.out, "panels", name), "wb").write(png)
                return None
            except urllib.error.HTTPError as e:
                # The renderer rate-limits adaptively (always allows >= 3); back off on 429.
                if e.code == 429 and attempt < 5:
                    time.sleep(2 * (attempt + 1))
                    continue
                return f"{p.get('title')}: {e}"
            except (urllib.error.URLError, OSError) as e:
                return f"{p.get('title')}: {e}"

    # A few renders in parallel (the renderer always admits at least 3).
    with ThreadPoolExecutor(max_workers=int(os.environ.get("RENDER_CONCURRENCY", "3"))) as pool:
        for err in pool.map(render_panel, enumerate(panels, 1)):
            if err:
                render_errors.append(err)
            else:
                rendered += 1

    # --- Time series + per-phase stats --------------------------------------
    window_s = (args.end - args.start) / 1000
    step = max(15, math.ceil(window_s / 10000))
    stats = {"window": {"from": args.start, "to": args.end, "step_s": step}, "phases": phases, "panels": []}
    with open(os.path.join(args.out, "metrics.csv"), "w", newline="") as fcsv:
        w = csv.writer(fcsv)
        w.writerow(["panel", "series", "unit", "timestamp_utc", "epoch_ms", "value", "labels"])
        for p in panels:
            unit = p.get("fieldConfig", {}).get("defaults", {}).get("unit", "")
            pstats = {"title": p.get("title"), "unit": unit, "series": []}
            for t in p.get("targets", []):
                expr = t.get("expr")
                if not expr:
                    continue
                try:
                    res = g.get(f"/api/datasources/proxy/uid/{PROM_DS}/api/v1/query_range",
                                {"query": expr, "start": args.start / 1000, "end": args.end / 1000, "step": step})
                except urllib.error.URLError as e:
                    pstats["series"].append({"series": t.get("legendFormat"), "expr": expr, "error": str(e)})
                    continue
                for s in res.get("data", {}).get("result", []):
                    labels = {k: v for k, v in s["metric"].items() if k != "__name__"}
                    name = legend(t.get("legendFormat"), labels, expr)
                    pts = []
                    for ts, val in s["values"]:
                        v = float(val)
                        ms = int(float(ts) * 1000)
                        pts.append((ms, v))
                        w.writerow([p.get("title"), name, unit,
                                    datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                    ms, val, json.dumps(labels, sort_keys=True)])
                    pstats["series"].append({
                        "series": name, "expr": expr,
                        "phases": {ph["name"]: phase_stats(pts, ph["start"], ph["end"]) for ph in phases},
                    })
            stats["panels"].append(pstats)
    json.dump(stats, open(os.path.join(args.out, "stats.json"), "w"), indent=2)

    # --- Markdown summary ---------------------------------------------------------
    names = [ph["name"] for ph in phases]
    with open(os.path.join(args.out, "stats.md"), "w") as f:
        f.write(f"# Grafana export{': ' + args.title if args.title else ''}\n\n")
        for ph in phases:
            f.write(f"- **{ph['name']}**: {ph['start']} → {ph['end']} ({(ph['end'] - ph['start']) / 60000:.1f} min)\n")
        f.write(f"\nMean per phase; 'steady max' is the maximum across all steady phases "
                "(chained runs have one per step). Unit as per panel.\n\n")
        f.write("| Panel | Series | " + " | ".join(names) + " | steady max |\n")
        f.write("|---|---|" + "---|" * len(names) + "---|\n")
        for ps in stats["panels"]:
            for s in ps["series"]:
                if "phases" not in s:
                    continue
                cells = [fmt((s["phases"].get(n) or {}).get("mean")) for n in names]
                smaxes = [(v or {}).get("max") for k, v in s["phases"].items() if k.startswith("steady")]
                smaxes = [v for v in smaxes if v is not None]
                smax = fmt(max(smaxes) if smaxes else None)
                f.write(f"| {ps['title']} ({ps['unit']}) | {s['series']} | " + " | ".join(cells) + f" | {smax} |\n")

    print(f"exported {len(panels)} panels, {rendered} PNGs, step {step}s -> {args.out}")
    for e in render_errors[:5]:
        print(f"  render warning: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
