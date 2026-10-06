#!/bin/bash
# T15: a rolling restart of every Vault node under leaf load (a routine
# operation: patching, config changes, the shape of an upgrade).
#   RUN_ID=t15 RATE=350 vault-rolling-restart.sh
#
# Under a constant leaf load through Consul (consul-leaf.js at RATE; remove
# Consul's CSR limits first), it restarts each Vault node in Raft in turn with
# `systemctl restart vault` (graceful: an active node steps down first), the
# active node last, as an operator would. After each: wait until Autopilot is
# healthy with failure tolerance back to where it was, then GAP (60s).
# With redundancy zones a restart that outlasts Autopilot's thresholds can
# promote the zone's spare; the layout before and after is recorded.
# Per node, from the restart to healthy + GAP:
#   healthy_s     restart -> Autopilot healthy, failure tolerance restored
#   max_gap_s     longest gap between successful leafs
#   failed_leafs  failed or timed-out leaf requests
#   signer_before / signer_after  the Vault node Consul signed through (did
#                 restarting it move Consul's connection?)
#   nlb           when the NLB stopped and resumed sending it requests (out_s,
#                 back_s; polled every 2 s)
# Writes <RUN_ID>-<node>-t15/t15.json, points.csv.gz, phases.json.
. /opt/perf/scripts/lib.sh

RATE=${RATE:-350}
GAP=${GAP:-60s}

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-t15"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"vault-rolling-restart","run_id":"$RUN_ID","node":"$PERF_NODE","rate":$RATE,"gap":"$GAP","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
PROM=$(prom_url)
INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId}' --output json)
busiest_signer() { # busiest_signer <unix s>: the Vault node with the most signs on Consul's intermediate in the minute before
  prom_query "$PROM" "sum by (instance) (increase(${SIGN_METRIC}[60s]))" "$1" | jq -r 'max_by(.value[1] | tonumber) | .metric.instance // empty'
}
# Autopilot healthy with failure tolerance >= <ft> (polled every 2 s, up to 10 min).
wait_ft() {
  local i a
  for i in $(seq 1 300); do
    a=$(VAULT_CLIENT_TIMEOUT=3s vault operator raft autopilot state -format=json 2>/dev/null) &&
      [ "$(jq -r '.Healthy // .healthy' <<<"$a")" = true ] &&
      [ "$(jq -r '.FailureTolerance // .failure_tolerance // 0' <<<"$a")" -ge "$1" ] && return 0
    sleep 2
  done
  return 1
}
layout() { vault-raft-voters.sh status | jq -c '{voters: .voter_nodes, non_voters, leader, failure_tolerance}'; }

restart_consul_agent
T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "T15 Vault rolling restart (run $RUN_ID, $RATE/s)" "perf,t15,$RUN_ID" "$T1")

stop_k6() { pkill -TERM -f -- "k6 run -e RUN_ID=$RUN_ID -e PERF_NODE=$PERF_NODE " 2>/dev/null || true; }
RAMP=30s HOLD=4h RATE=$RATE K6_CSV_TIME_FORMAT=unix_milli BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/consul-leaf.js --out "csv=$OUT/points.csv" --no-thresholds > "$OUT/k6.log" 2>&1 &
k6_pid=$!
trap stop_k6 EXIT
sleep 150 # ramp, then a minute of steady signing

before=$(layout)
ft0=$(jq -r '.failure_tolerance // 2' <<<"$before")
leader=$(jq -r .leader <<<"$before")
# Every node in Raft (not held or removed instances, which a restart would
# start), the active one last.
order=$(vault operator raft list-peers -format=json |
  jq -r --arg l "$leader" '[.data.config.servers[].node_id | select(. != $l)] | sort + [$l] | .[]')
echo "$(date -u +%H:%M:%S) restart order: $(echo $order) (failure tolerance $ft0)"
reps='[]'
PHASE_LIST='[]'
for n in $order; do
  iid=$(jq -r --arg n "$n" '.[] | select(.node == $n) | .id' <<<"$INST")
  sb=$(busiest_signer "$(date +%s)")
  SID=$(annotate "T15: restart $n" "perf,t15-step,$RUN_ID")
  r0=$(now_ms)
  nlb_watch_start "$iid" "$OUT/nlb.$n.txt"
  echo "$(date -u +%H:%M:%S) restarting $n"
  ssm_run 180 'systemctl restart vault && echo restarted' "$iid" >/dev/null
  if wait_ft "$ft0"; then h=$(now_ms); else h=null; echo "  $n: not healthy within 10 minutes" >&2; fi
  annotate_end "$SID"
  idle "t15 gap" "$GAP"
  r1=$(now_ms)
  nlb_watch_stop "$OUT/nlb.$n.txt"
  sa=$(busiest_signer "$(date +%s)")
  reps=$(jq -c --arg n "$n" --arg sb "$sb" --arg sa "$sa" --argjson r0 "$r0" --argjson r1 "$r1" --argjson h "$h" --arg l "$leader" \
    --argjson nlb "$(nlb_watch_summary "$OUT/nlb.$n.txt" "$r0")" \
    '. + [{node: $n, was_active: ($n == $l), start_ms: $r0, end_ms: $r1, nlb: $nlb,
           healthy_s: (if $h then ($h - $r0) / 1000 else null end),
           signer_before: $sb, signer_after: $sa}]' <<<"$reps")
  PHASE_LIST=$(jq -c --arg n "$n" --argjson s "$r0" --argjson e "$r1" '. + [{name: "restart-\($n)", start: $s, end: $e}]' <<<"$PHASE_LIST")
done
after=$(layout)

stop_k6
wait "$k6_pid" 2>/dev/null || true
trap - EXIT
T3=$(now_ms)
annotate_end "$AID" "$T3"

echo "$reps" > "$OUT/repeats.in.json"
python3 - "$OUT/points.csv" "$OUT/repeats.in.json" > "$OUT/repeats.json" <<'PY'
import csv, json, sys
reps = json.load(open(sys.argv[2]))
ok, bad = [], []
for row in csv.DictReader(open(sys.argv[1])):
    if row.get("metric_name") != "http_reqs" or row.get("name") != "leaf":
        continue
    t = float(row["timestamp"]); t = t if t > 1e11 else t * 1000
    (ok if row.get("status") == "200" else bad).append(t)
ok.sort()
for r in reps:
    a, b = r["start_ms"], r["end_ms"]
    before = [t for t in ok if t < a]
    around = ([before[-1]] if before else []) + [t for t in ok if a <= t <= b]
    gaps = [y - x for x, y in zip(around, around[1:])]
    r["max_gap_s"] = round(max(gaps) / 1000, 2) if gaps else None
    r["failed_leafs"] = sum(1 for t in bad if a <= t <= b)
print(json.dumps(reps))
PY
gzip -f "$OUT/points.csv"
jq --argjson b "$before" --argjson a "$after" '. as $r
  | {nodes: $r, layout_before: $b, layout_after: $a, failed_leafs: ([$r[].failed_leafs] | add),
     max_gap_s: ([$r[].max_gap_s | select(. != null)] | max), healthy_s_max: ([$r[].healthy_s | select(. != null)] | max),
     never_healthy: [$r[] | select(.healthy_s == null) | .node]}' "$OUT/repeats.json" > "$OUT/t15.json"
rm -f "$OUT/repeats.json" "$OUT/repeats.in.json"
jq -c '{failed_leafs, max_gap_s, healthy_s_max, never_healthy, layout_after}' "$OUT/t15.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)
jq -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson t3 "$T3" --argjson t4 "$T4" --argjson f "$PHASE_LIST" \
  '[{name: "baseline", start: $t0, end: $t1}] + $f + [{name: "cooldown", start: $t3, end: $t4}] | map(select(.end > .start))' > "$OUT/phases.json"
export_grafana "$OUT" "T15 Vault rolling restart ($RUN_ID)"
upload_results "$OUT"
