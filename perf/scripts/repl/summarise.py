#!/usr/bin/env python3
"""RESULTS.md for a T17 run (repl-1, issue #23): summarise.py <results dir>.

Reads the run's events.jsonl, probes.jsonl, status.jsonl, the verify.py
outputs, and the k6 summaries, and writes Markdown to stdout: Table 6 with the
observed results next to the expected ones, then the evidence for each row.
"""
import glob
import json
import os
import sys
from datetime import datetime

RES = sys.argv[1] if len(sys.argv) > 1 else "."


def jsonl(name):
    out = []
    path = os.path.join(RES, name)
    if not os.path.exists(path):
        return out
    with open(path, errors="replace") as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def load(name):
    try:
        with open(os.path.join(RES, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def hms(secs):
    secs = int(round(secs))
    return f"{secs // 3600}h {secs % 3600 // 60:02d}m {secs % 60:02d}s" if secs >= 3600 else f"{secs // 60}m {secs % 60:02d}s"


events = jsonl("events.jsonl")
probes = jsonl("probes.jsonl")
status = jsonl("status.jsonl")


def ev(name, **match):
    return [e for e in events if e.get("event") == name and all(e.get(k) == v for k, v in match.items())]


def probe_summary(prefix, cluster):
    """-> (as expected?, text) for every probe whose label starts with prefix."""
    ps = [p for p in probes if p["label"].startswith(prefix) and p["cluster"] == cluster]
    if not ps:
        return None, "not run"
    bad = [p for p in ps if not p["as_expected"]]
    by_op = {}
    for p in ps:
        by_op.setdefault(p["op"], []).append(p)
    parts = []
    for op, rows in by_op.items():
        ok = sum(1 for r in rows if r["ok"])
        parts.append(f"{op} {ok}/{len(rows)} succeeded")
    head = "As expected." if not bad else f"**{len(bad)} of {len(ps)} not as expected.**"
    return not bad, head + " " + "; ".join(parts) + "."


def transitions(cluster, kind, since):
    """State changes of <cluster>'s <kind> replication after `since` (epoch s)."""
    out, last = [], None
    for s in status:
        if s.get("cluster") != cluster or ts(s["ts"]) < since:
            continue
        st = (s.get(kind) or {}).get("state")
        if st != last:
            out.append((ts(s["ts"]), st))
            last = st
    return out


def phases(cluster, kind, since, until):
    """Time in each state between the restore and the end of catch-up. A cut-off
    secondary can keep reporting stream-wals, so the window, not the first
    stream-wals sample, marks the end."""
    t = [(at, st) for at, st in transitions(cluster, kind, since) if at <= until]
    rows = []
    for i, (start, st) in enumerate(t):
        end = t[i + 1][0] if i + 1 < len(t) else until
        if st:
            rows.append((st, start - since, end - start))
    return rows


def catchup_text(cluster, kind, label):
    end = ev("cut_end", link=label)
    if not end:
        return "not run"
    since = ts(end[0]["ts"])
    if label == "dr-primary":
        done = ev("dr_reconnect_done")
    else:
        done = ev("catchup", cluster=cluster, label=label)
    until = since + float(done[0]["secs"]) + (ts(done[0]["ts"]) - since - float(done[0]["secs"]) if label == "dr-primary" else 0) if done else since + 3600
    rows = phases(cluster, kind, since, until)
    if not rows:
        return "no status samples"
    merkle = any(st in ("merkle-diff", "merkle-sync") for st, _, _ in rows)
    path = "Merkle diff and sync" if merkle else "streaming from the buffer"
    if label == "dr-primary":
        cu = [{"ok": "true", "secs": e["secs"]} for e in ev("dr_reconnect_done")]
    else:
        cu = [e for e in ev("catchup", cluster=cluster, label=label)]
    if cu and cu[0].get("ok") == "true":
        total = f"caught up {hms(float(cu[0]['secs']))} after the link returned"
    elif cu:
        total = "**not caught up**"
    else:
        done = [r for r in rows if r[0] == "stream-wals"]
        total = f"state stream-wals {hms(done[0][1])} after the link returned" if done else "**not back to stream-wals**"
    steps = ", ".join(f"{st} {hms(d)}" for st, _, d in rows if d is not None and st != "stream-wals")
    return f"{path}; {total}" + (f" ({steps})" if steps else "")


def wal_gap():
    """PR secondary's gap behind the primary during the PR cut, first and last sample."""
    start = ev("cut_start", link="pr")
    end = ev("cut_end", link="pr")
    if not start or not end:
        return None
    a, b = ts(start[0]["ts"]), ts(end[0]["ts"])
    prim = [(ts(s["ts"]), (s.get("performance") or {}).get("last_performance_wal")) for s in status
            if s.get("cluster") == "primary" and a <= ts(s["ts"]) <= b]
    sec = [(ts(s["ts"]), (s.get("performance") or {}).get("last_remote_wal")) for s in status
           if s.get("cluster") == "pr-sec" and a <= ts(s["ts"]) <= b]
    if not prim or not sec:
        return None
    return {"start": (prim[0][1] or 0) - (sec[0][1] or 0), "end": (prim[-1][1] or 0) - (sec[-1][1] or 0)}


def final_wals():
    fs = {e["cluster"]: json.loads(e["status"]) for e in ev("final_status") if e.get("status")}
    if not fs:
        return []
    rows = []
    p = fs.get("primary", {})
    s = fs.get("pr-sec", {})
    rows.append(("pr-sec (PR)", (p.get("performance") or {}).get("last_performance_wal"),
                 (s.get("performance") or {}).get("last_remote_wal"),
                 (p.get("performance") or {}).get("merkle_root"), (s.get("performance") or {}).get("merkle_root")))
    rows.append(("primary-dr (DR)", (p.get("dr") or {}).get("last_dr_wal"), (fs.get("primary-dr", {}).get("dr") or {}).get("last_remote_wal"),
                 (p.get("dr") or {}).get("merkle_root"), (fs.get("primary-dr", {}).get("dr") or {}).get("merkle_root")))
    rows.append(("pr-sec-dr (DR)", (s.get("dr") or {}).get("last_dr_wal"), (fs.get("pr-sec-dr", {}).get("dr") or {}).get("last_remote_wal"),
                 (s.get("dr") or {}).get("merkle_root"), (fs.get("pr-sec-dr", {}).get("dr") or {}).get("merkle_root")))
    return rows


# Which cut takes each DR link down.
DR_PAIRS = [("primary-dr", "primary", ("dr-primary", "both")), ("pr-sec-dr", "pr-sec", ("both",))]
LAG_STEPS = ["load", "dr-cut", "both-cut", "pr-cut", "verify"]


def dr_lag():
    """Each DR replica's lag behind its primary per step, from samples with its own link up.

    Lag = primary last_dr_wal - replica last_remote_wal, matched to the second.
    Seconds = WALs / the primary's average WAL rate under load (from the load
    step to verify, when the load stops).
    """
    steps = [(e.get("step"), ts(e["ts"])) for e in ev("step_start")]
    bounds = {}
    for i, (name, t) in enumerate(steps):
        if name in LAG_STEPS:
            bounds[name] = (t, steps[i + 1][1] if i + 1 < len(steps) else float("inf"))
    cuts = {}
    for e in ev("cut_start"):
        end = [ts(x["ts"]) for x in ev("cut_end", link=e.get("link")) if ts(x["ts"]) >= ts(e["ts"])]
        cuts.setdefault(e.get("link"), []).append((ts(e["ts"]), end[0] if end else float("inf")))
    by = {}
    for r in status:
        d = r.get("dr") or {}
        by.setdefault(r.get("cluster"), {})[int(ts(r["ts"]))] = d
    rows = []
    for rep, prim, links in DR_PAIRS:
        down = [w for l in links for w in cuts.get(l, [])]
        rate = 0
        if "load" in bounds:
            a, b = bounds["load"][0], bounds.get("verify", (float("inf"),))[0]
            w = [(t, d.get("last_dr_wal")) for t, d in sorted(by.get(prim, {}).items()) if a <= t < b and d.get("last_dr_wal") is not None]
            if len(w) > 1 and w[-1][0] > w[0][0]:
                rate = (w[-1][1] - w[0][1]) / (w[-1][0] - w[0][0])
        for name in LAG_STEPS:
            if name not in bounds:
                continue
            a, b = bounds[name]
            lags = []
            for sec, pd in sorted(by.get(prim, {}).items()):
                if not (a <= sec < b) or any(x <= sec <= y for x, y in down):
                    continue
                rd = by.get(rep, {}).get(sec)
                pw, rw = pd.get("last_dr_wal"), (rd or {}).get("last_remote_wal")
                if pw is None or rw is None:
                    continue
                lags.append(pw - rw)
            if not lags:
                continue
            lags.sort()
            mx = lags[-1]
            rows.append((rep, prim, name, len(lags), lags[len(lags) // 2], mx, rate, mx / rate if rate > 0 else None))
    return rows


def guards(label):
    g = {(e["cluster"]): json.loads(e["counters"]) for e in ev("guards") if e.get("label") == label and e.get("counters")}
    return g


def k6_rows():
    rows = []
    for f in sorted(glob.glob(os.path.join(RES, "load-*", "*", "summary.json"))):
        node, name = f.split(os.sep)[-3][5:], f.split(os.sep)[-2]
        try:
            m = json.load(open(f))["metrics"]
        except (OSError, ValueError, KeyError):
            continue
        reqs = m.get("http_reqs", {}).get("values", {}).get("count", 0)
        failed = m.get("http_req_failed", {}).get("values", {}).get("rate", 0)
        p99 = m.get("http_req_duration", {}).get("values", {}).get("p(99)", 0)
        rows.append((node, name, int(reqs), failed, p99))
    return rows


def main():
    o = []
    start = ev("run_start")
    done = ev("run_done")
    o.append(f"# T17 results: {os.path.basename(RES.rstrip('/'))}\n")
    if start:
        last = done[-1]["ts"] if done else events[-1]["ts"]
        o.append(f"Started {start[0]['ts']}, last event {last} ({hms(ts(last) - ts(start[0]['ts']))}).\n")
        o.append("Settings: `" + " ".join(x for x in start[0].get("settings", "").split() if not x.endswith("=")) + "`\n")

    # --- Table 6 ---
    dr_m = load("writes-missing-primary-dr.json") or {}
    o.append("## Table 6: expected and observed\n")
    o.append("| Cut | Primary's side | PR secondary's side | Protection lost |")
    o.append("|---|---|---|---|")
    _, a = probe_summary("dr-cut", "primary")
    _, b = probe_summary("dr-cut", "pr-sec")
    prot = (f"Promoted during the cut: {dr_m.get('missing_after_cut', '?')} of {dr_m.get('writes_after_cut', '?')} writes made after the cut missing; "
            f"{dr_m.get('keys_missing_writes_from_before_cut', '?')} keys missing writes from before it.") if dr_m else "Promotion not run."
    o.append(f"| DR link (primary to primary-dr) | Expected: no effect. Observed: {a} | Expected: no effect. Observed: {b} | {prot} Catch-up after reconnecting: {catchup_text('primary-dr', 'dr', 'dr-primary')}. |")
    _, a = probe_summary("both-cut", "primary")
    _, b = probe_summary("both-cut", "pr-sec")
    o.append(f"| Both | Expected: no effect. Observed: {a} | Expected: as for the PR link. Observed: {b} | Catch-up: pr-sec {catchup_text('pr-sec', 'performance', 'both')}; primary-dr {catchup_text('primary-dr', 'dr', 'both')}; pr-sec-dr {catchup_text('pr-sec-dr', 'dr', 'both')}. |")
    _, a = probe_summary("pr-cut", "primary")
    _, b = probe_summary("pr-cut", "pr-sec")
    o.append(f"| PR link (primary to pr-sec), held {start[0].get('settings', '').split('PR_HOLD=')[1].split()[0] if start and 'PR_HOLD=' in start[0].get('settings', '') else '?'} | Expected: no effect. Observed: {a} | Expected: reads, issuance, logins, and renewals continue; writes, PKI role changes, CA configuration changes, and cross-cluster revocation fail. Observed: {b} | Expected: none for DR. Catch-up: {catchup_text('pr-sec', 'performance', 'pr')}. |")
    o.append("")

    # --- probes ---
    o.append("## Every probe\n")
    o.append("Each operation from Table 6, tried once per label. Expect: what should happen. A row is flagged when the result differs.\n")
    o.append("| Label | Cluster | Operation | Code | Expect | As expected |")
    o.append("|---|---|---|---|---|---|")
    for p in probes:
        o.append(f"| {p['label']} | {p['cluster']} | {p['op']} | {p['code']} | {p['expect']} | {'yes' if p['as_expected'] else '**no**'} |")
    o.append("")

    # --- catch-up, buffer ---
    o.append("## Catch-up after the PR cut\n")
    g = guards("pr").get("primary")
    if g:
        o.append(f"- Log shipper on the primary, from the start of the cut to the end of catch-up: `missing_guard` +{g.get('missing_guard')}, "
                 f"`guard_found` +{g.get('guard_found')}, `buffer_over_run` +{g.get('buffer_over_run')}. "
                 "A rise in `missing_guard` means the buffer no longer held what the secondary asked for.")
    gap = wal_gap()
    if gap:
        o.append(f"- WAL gap (primary `last_performance_wal` minus pr-sec `last_remote_wal`): {gap['start']} at the start of the cut, {gap['end']} at the end.")
    o.append(f"- Path and time: {catchup_text('pr-sec', 'performance', 'pr')}.")
    for e in ev("catchup"):
        o.append(f"- {e['label']}: {e['cluster']} ({e['type']}) " + (f"streaming after {hms(float(e['secs']))}" if e.get("ok") == "true" else f"**not streaming** (state {e.get('state')})"))
    o.append("")

    o.append("## Data after catch-up\n")
    pairs = ev("final_pair")
    if pairs:
        o.append("WAL indexes and Merkle roots with the load stopped, each secondary sampled at its primary's WAL index:\n")
        o.append("| Secondary | Primary's WAL | Secondary's last_remote_wal | Primary's merkle_root | Secondary's merkle_root | Match | Waited |")
        o.append("|---|---|---|---|---|---|---|")
        for p in pairs:
            match = "yes" if p["primary_wal"] == p["secondary_wal"] and p["primary_root"] == p["secondary_root"] else "**no**"
            waited = hms(float(p["secs"])) if p.get("secs") else "?"
            o.append(f"| {p['secondary']} ({p['type']}) | {p['primary_wal']} | {p['secondary_wal']} | {p['primary_root'][:12]} | {p['secondary_root'][:12]} | {match} | {waited} |")
        o.append("")
        o.append("Waited: time after the load stopped until the WAL indexes matched, up to FINAL_WAIT.\n")
    lag = dr_lag()
    if lag:
        o.append("## DR lag with the link up\n")
        o.append("How far each DR replica ran behind its primary in each step, counting only samples while its own link was up "
                 "(the time after a cut, while it catches up, is included). A DR promotion at that moment would lose these writes. "
                 "Seconds: the WAL gap divided by the primary's average WAL rate under load.\n")
        o.append("| DR replica | Step | Samples | Median gap (WALs) | Max gap (WALs) | Primary's WALs/s under load | Max gap (s) |")
        o.append("|---|---|---|---|---|---|---|")
        for rep, prim, name, n, med, mx, rate, secs in lag:
            o.append(f"| {rep} (of {prim}) | {name} | {n} | {med} | {mx} | {rate:.0f} | {hms(secs) if secs is not None else '?'} |")
        o.append("")
    mc = load("manifest-check-pr-sec.json")
    if mc:
        o.append(f"- Planned changes made during the PR cut: {mc['checked'] - mc['failed']} of {mc['checked']} read back on pr-sec as recorded." + ("" if mc["ok"] else f" **Failures:** `{json.dumps(mc['failures'][:5])}`"))
    wf = load("writes-final-pr-sec.json")
    if wf:
        o.append(f"- KV load: {wf['keys']} keys ({wf['writes']} writes); {wf['behind']} behind on pr-sec, {wf['read_errors']} read errors.")
    o.append("")

    o.append("## Cross-cluster revocation, OPS-B, and stale data\n")
    for e in ev("revoke_confirm"):
        o.append(f"- Leaf `{e['leaf']}`: revoked on the primary: {e['revoked']} ({e['secs']} s after the request).")
    reads = ev("marker_read")
    stale = [r for r in reads if r.get("primary") != r.get("pr_sec")]
    if reads:
        o.append(f"- Marker key: pr-sec served an older value than the primary in {len(stale)} of {len(reads)} reads during the PR cut.")
    o.append("")

    o.append("## Client load (whole run)\n")
    o.append("| Load generator | Load | Requests | Failed | p99 (ms) |")
    o.append("|---|---|---|---|---|")
    for node, name, reqs, failed, p99 in k6_rows():
        o.append(f"| {node} | {name} | {reqs} | {failed:.2%} | {p99:.0f} |")
    o.append("")
    o.append("Failures here include the ones Table 6 expects, such as KV writes on pr-sec during the cuts. Per-cut rates are in Prometheus (`k6_http_reqs_total` by `node` and `load`).\n")

    errs = ev("error")
    if errs:
        o.append("## Errors\n")
        for e in errs:
            o.append(f"- {e['ts']}: {e.get('msg')}")
    print("\n".join(o))


if __name__ == "__main__":
    main()
