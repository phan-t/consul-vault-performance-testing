#!/usr/bin/env python3
"""Generate terraform/files/consul-vault-perf.json (Grafana dashboard).

Layout: every row holds three equal panels (w=8, h=8) with compact list legends,
so plot areas are identical regardless of how many series a panel has.

Notes on the metrics used (validated against Consul 2.0.4+ent / Vault 2.1.1+ent):
  * Consul does not export consul_rpc_server_call here, so leaf signing is
    measured via the Raft FSM op each ConnectCA.Sign performs
    (consul_fsm_ca_leaf{op="increment-index"}). Every server applies the same
    log entry, so use max() across servers, not sum().
  * Raft library metrics (consul_raft_commitTime, leader_lastContact, ...)
    need Consul 2.0.1+ent: 2.0.2-2.0.4 release binaries drop them
    (hashicorp/consul#23812). The environment pins 2.0.1.
  * Summary quantiles are NaN when there were no samples in the retention
    window (idle); ">= 0" filters those out, and _sum/_count rates give an
    average that is defined whenever there is traffic.

Run: python3 scripts/gen-dashboard.py
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "terraform" / "files" / "consul-vault-perf.json"
DS = {"type": "prometheus", "uid": "prometheus"}
W, H, COLS = 8, 8, 3

panels = []
_s = {"id": 1, "y": 0, "col": 0}


def _place():
    """Next slot in a 3-column grid."""
    if _s["col"] == COLS:
        _s["y"] += H
        _s["col"] = 0
    pos = {"h": H, "w": W, "x": _s["col"] * W, "y": _s["y"]}
    _s["col"] += 1
    return pos


def row(title):
    if _s["col"]:
        _s["y"] += H
    _s["col"] = 0
    panels.append({"type": "row", "title": title, "id": _s["id"], "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _s["y"]}, "panels": []})
    _s["id"] += 1
    _s["y"] += 1


def _targets(targets):
    return [{"datasource": DS, "refId": chr(65 + i), "expr": e, "legendFormat": l}
            for i, (e, l) in enumerate(targets)]


def ts(title, targets, unit="short", desc="", decimals=None, draw="line", minv=None):
    defaults = {"unit": unit,
                "custom": {"drawStyle": draw, "lineWidth": 1, "fillOpacity": 10, "spanNulls": True,
                           "lineInterpolation": "stepAfter" if draw == "line" and unit == "none" else "linear"}}
    if decimals is not None:
        defaults["decimals"] = decimals
    if minv is not None:
        defaults["min"] = minv
    panels.append({
        "type": "timeseries", "title": title, "id": _s["id"], "datasource": DS, "description": desc,
        "gridPos": _place(),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "calcs": []},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "targets": _targets(targets),
    })
    _s["id"] += 1


def leader_timeline(title, expr, desc, on="Leader", off="Follower"):
    panels.append({
        "type": "state-timeline", "title": title, "id": _s["id"], "datasource": DS, "description": desc,
        "gridPos": _place(),
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [{"color": "#6e7079", "value": None},
                                                             {"color": "green", "value": 1}]},
                "mappings": [{"type": "value", "options": {"0": {"text": off, "color": "#6e7079"},
                                                           "1": {"text": on, "color": "green"}}}],
                "custom": {"fillOpacity": 80, "lineWidth": 0},
            },
            "overrides": [],
        },
        "options": {"showValue": "never", "mergeValues": True, "rowHeight": 0.8,
                    "legend": {"showLegend": False}, "tooltip": {"mode": "single"}},
        "targets": _targets([(expr, "{{instance}}")]),
    })
    _s["id"] += 1


def avg_of(metric, by="instance"):
    return f"sum by ({by}) (rate({metric}_sum[1m])) / sum by ({by}) (rate({metric}_count[1m]))"


INTER = '{__name__=~"vault_route_update_connect_.*_inter__count"}'
INTER_Q = lambda q: f'{{__name__=~"vault_route_update_connect_.*_inter_",quantile="{q}"}}'

# --- Leadership & quorum -------------------------------------------------------
row("Leadership & quorum")
leader_timeline("Consul leader", "max by (instance) (consul_server_isLeader)",
                "Which Consul server is Raft leader over time (only the leader signs leaf CSRs).")
leader_timeline("Vault active node", "max by (instance) (vault_core_active)",
                "Which Vault node is active over time. Standbys still serve no_store signing locally.",
                on="Active", off="Standby")
ts("Leader elections (per 5m)",
   [("sum(increase(consul_raft_state_leader[5m]))", "Consul leaders elected"),
    ("sum(increase(consul_raft_state_candidate[5m]))", "Consul candidacies"),
    ("sum(changes(vault_core_active[5m])) / 2", "Vault leadership changes")],
   "none", "Consul: Raft state counters (candidacies > leaders elected means failed/split votes). Vault: active-node flips (/2 because one node goes 1->0 and another 0->1). Any non-zero value during a test is worth investigating.",
   decimals=0, minv=0)
ts("Autopilot failure tolerance",
   [("min(consul_autopilot_failure_tolerance)", "Consul"),
    ("min(vault_autopilot_failure_tolerance)", "Vault")],
   "none", "How many voters can fail without losing quorum (5 voters = 2).", decimals=0, minv=0)
ts("Autopilot healthy",
   [("min(consul_autopilot_healthy)", "Consul"),
    ("min(vault_autopilot_healthy)", "Vault")],
   "none", "1 = all servers healthy per Autopilot.", decimals=0, minv=0)
ts("Vault leader contact (followers)",
   [('max by (instance) (vault_raft_leader_lastContact{quantile="0.99"} >= 0)', "p99 {{instance}}")],
   "ms", "Time since followers last heard from the leader. Rising values precede elections.")

# --- Consul Raft ---------------------------------------------------------------
# Needs Consul 2.0.1+ent: 2.0.2-2.0.4 release binaries drop Raft library
# metrics (hashicorp/consul#23812).
row("Consul Raft")
ts("Consul Raft commit time",
   [(avg_of("consul_raft_commitTime"), "avg {{instance}}"),
    ('max by (instance) (consul_raft_commitTime{quantile="0.99"} >= 0)', "p99 {{instance}}"),
    ('max by (instance) (consul_raft_commitTime{quantile="0.5"} >= 0)', "p50 {{instance}}")],
   "ms", "Time for the leader to commit a log entry (quorum append). Leader-only; every leaf signing is one Raft write.")
ts("Consul Raft leader last contact",
   [('max by (instance) (consul_raft_leader_lastContact{quantile="0.99"} >= 0)', "p99 {{instance}}")],
   "ms", "Time since the leader last heard from followers. Rising values precede elections.")
ts("Consul Raft applies / s",
   [("sum(rate(consul_raft_apply[1m]))", "raft applies/s"),
    ('max(rate(consul_fsm_ca_leaf_count{op="increment-index"}[1m]))', "of which leaf signings"),
    ("sum(max by (op) (rate(consul_fsm_kvs_count[1m])))", "of which KV ops")],
   "ops", "Raft log applies on the leader (raft.apply), with the leaf-signing and KV share from FSM counters.")

# --- Consul Connect CA -------------------------------------------------------
row("Consul Connect CA (leaf signing via Vault)")
ts("Leaf certificates signed / s",
   [('max(rate(consul_fsm_ca_leaf_count{op="increment-index"}[1m]))', "signed/s (cluster)")],
   "reqps", "Each ConnectCA.Sign bumps the CA leaf index via Raft. Only the Consul leader signs; all servers apply the entry, hence max().")
ts("Consul RPC requests / errors per server",
   [("sum by (instance) (rate(consul_rpc_request[1m]))", "req {{instance}}"),
    ("sum by (instance) (rate(consul_rpc_request_error[1m]))", "err {{instance}}")],
   "reqps")
ts("Consul FSM apply time (leaf index)",
   [('max by (instance) (consul_fsm_ca_leaf{op="increment-index",quantile="0.99"} >= 0)', "p99 {{instance}}")],
   "ms", "Time to apply each leaf-signing Raft entry to the state store.")
ts("Consul → Vault TCP connections",
   [('max by (instance) (perf_vault_connections{role="consul"})', "{{instance}}")],
   "none", "Established connections from each Consul server to Vault :8200 (ss, every 5s). The leader's Vault CA provider is expected to use one pooled HTTP/2 connection.",
   decimals=0, minv=0)
ts("Leaf signing concentration (busiest Vault node)",
   [(f"max(sum by (instance) (rate({INTER}[1m]))) / sum(rate({INTER}[1m]))", "busiest node share")],
   "percentunit", "Share of sign requests on Consul's intermediate served by the busiest Vault node. ~100% = pinned to one node (one connection).",
   minv=0)
ts("Consul server CPU",
   [('100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",role="consul"}[1m])) * 100', "{{instance}}")],
   "percent", "The leader signs every CSR; with Consul Dataplane, servers also generate proxy keys.")

# --- Vault ---------------------------------------------------------------------
row("Vault")
ts("Vault requests handled per node",
   [("sum by (instance) (rate(vault_core_handle_request_count[1m]))", "{{instance}}")],
   "reqps", "With no_store=true, performance standbys (incl. non-voters) sign locally. Direct clients spread across nodes; the Consul leader's pooled connection usually pins its signing to one node.")
ts("Vault request latency",
   [(avg_of("vault_core_handle_request"), "avg {{instance}}"),
    ('max by (instance) (vault_core_handle_request{quantile="0.99"} >= 0)', "p99 {{instance}}")],
   "ms")
ts("Vault sign latency (Consul intermediate)",
   [(f"max by (instance) ({INTER_Q('0.99')} >= 0)", "p99 {{instance}}"),
    (f"max by (instance) ({INTER_Q('0.5')} >= 0)", "p50 {{instance}}")],
   "ms", "Vault-side time for <connect_dc_inter>/sign/leaf-cert - the call the Consul leader makes per leaf.")
ts("Vault sign requests (Consul intermediate) / s",
   [(f"sum by (instance) (rate({INTER}[1m]))", "{{instance}}")],
   "reqps")
ts("Vault Raft commit time",
   [(avg_of("vault_raft_commitTime"), "avg {{instance}}"),
    ('max by (instance) (vault_raft_commitTime{quantile="0.99"} >= 0)', "p99 {{instance}}")],
   "ms", "no_store signing does not write to Raft; this moves with other writes.")
ts("Vault leadership lost / setup failed",
   [("sum(increase(vault_core_leadership_lost_count[5m]))", "leadership lost"),
    ("sum(increase(vault_core_leadership_setup_failed_count[5m]))", "setup failed")],
   "none", decimals=0, minv=0)

# --- Load generators (k6 client-side, via Prometheus remote write) -------------
row("Load generators (k6 client-side)")
ts("Client requests / failures per second",
   [("sum by (name) (rate(k6_http_reqs_total[1m]))", "req {{name}}"),
    ('sum by (name) (rate(k6_http_reqs_total{expected_response="false"}[1m]))', "failed {{name}}")],
   "reqps", "What the load generators sent, summed across nodes. 'name' is the k6 request tag (leaf, sign, register, leaf_wait).")
ts("Client latency (worst load generator)",
   [("max by (name) (k6_http_req_duration_p99)", "p99 {{name}}"),
    ("max by (name) (k6_http_req_duration_p95)", "p95 {{name}}"),
    ("max by (name) (k6_http_req_duration_p50)", "p50 {{name}}")],
   "s", "Caller-observed latency from k6 (remote write trend stats), worst node per request name.")
ts("Burst: registration to leaf ready",
   [("max(k6_leaf_ready_ms_p99)", "p99"),
    ("max(k6_leaf_ready_ms_p50)", "p50"),
    ("sum(rate(k6_sidecars_registered_total[1m]))", "sidecars registered/s")],
   "s", "consul-register-burst.js only: time from sidecar registration until its leaf is available.")

# --- Hosts -----------------------------------------------------------------------
row("Hosts")
ts("CPU utilisation",
   [('100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100', "{{instance}}")], "percent")
ts("Memory used",
   [("1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes", "{{instance}}")], "percentunit")
ts("Disk space used",
   [('max by (instance) (1 - node_filesystem_avail_bytes{fstype=~"xfs|ext4"} / node_filesystem_size_bytes{fstype=~"xfs|ext4"})', "{{instance}}")],
   "percentunit", "Fullest filesystem per host (root, Raft data, audit log).")
ts("Disk write IOPS",
   [('sum by (instance) (rate(node_disk_writes_completed_total{device=~"nvme.*"}[1m]))', "{{instance}}")], "iops")
ts("Network receive",
   [('sum by (instance) (rate(node_network_receive_bytes_total{device!="lo"}[1m]))', "{{instance}}")], "Bps")
ts("Network transmit",
   [('sum by (instance) (rate(node_network_transmit_bytes_total{device!="lo"}[1m]))', "{{instance}}")], "Bps")
leader_timeline("Security scanner active", "max by (instance) (perf_scanner_active)",
                "perf_scanner_active: a security/inventory scanner (e.g. a vulnerability scanner on the image) is running. Scans cost CPU; run-plan.sh waits for them before testing and flags tests they overlapped.",
                on="Scanning", off="Idle")
ts("CPU steal",
   [('avg by (instance) (rate(node_cpu_seconds_total{mode="steal"}[1m])) * 100', "{{instance}}")],
   "percent", "Time the hypervisor gave to other tenants. Non-zero on burstable (t3/t4g) instances when out of credits.", minv=0)
ts("CPU I/O wait",
   [('avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[1m])) * 100', "{{instance}}")],
   "percent", "CPU idle while waiting for disk (Raft data volumes, audit log).", minv=0)

dashboard = {
    "title": "Consul + Vault Perf", "uid": "consul-vault-perf", "schemaVersion": 39, "version": 9, "editable": True,
    "time": {"from": "now-1h", "to": "now"}, "refresh": "10s", "tags": ["consul", "vault", "perf"],
    "panels": panels, "templating": {"list": []},
    "annotations": {"list": [
        {"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True,
         "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"},
        {"datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "iconColor": "orange",
         "name": "Perf tests", "target": {"type": "tags", "tags": ["perf"], "matchAny": True, "limit": 200}},
    ]},
}
OUT.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {OUT} ({len([p for p in panels if p['type'] != 'row'])} panels)")
