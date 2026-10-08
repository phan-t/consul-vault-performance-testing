#!/bin/bash
# T3f: what sidecars see when the Vault node Consul signs through hangs.
#   RUN_ID=t3f RATE=200 consul-vault-failover.sh
#
# The Consul leader's Vault CA provider keeps one HTTP/2 connection, so all
# signing goes through one Vault node (T3c, T6). Under a constant leaf load
# through Consul (consul-leaf.js at RATE; remove Consul's CSR limits first), it:
#   1. finds that node: the Vault node with the most signs on Consul's
#      intermediate over the last minute (Prometheus), and whether it's active;
#   2. freezes it with SIGSTOP for FREEZE (60s), then SIGCONT (unplanned, like
#      T11 and T12; if it's the active node, Vault also elects a new one);
#   3. waits for Autopilot healthy, keeps the load AFTER (2m), then stops.
# From k6's per-request samples, over the freeze to FREEZE + 60 s:
#   failed_leafs     failed or timed-out leaf requests (k6 timeout 60 s)
#   error_window_s   first to last failure
#   max_gap_s        longest gap between successful leafs: how long sidecars
#                    could get no certificate at all
#   recovered_s      freeze -> the end of the last disrupted 5 s window (a
#                    failure, or under 90% of RATE succeeding)
# and from Prometheus, which Vault node signed most in the minute after the
# freeze (did Consul move to another node, or wait for the frozen one?), and
# from the NLB (polled every 2 s) when it stopped and resumed sending requests
# to the frozen node (nlb.out_s, nlb.back_s).
# Writes <RUN_ID>-<node>-t3f/t3f.json, points.csv.gz, phases.json.
. /opt/perf/scripts/lib.sh

RATE=${RATE:-200}
FREEZE=${FREEZE:-60s}
AFTER=${AFTER:-2m}
freeze_s=$(to_secs "$FREEZE")

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-t3f"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"consul-vault-failover","run_id":"$RUN_ID","node":"$PERF_NODE","rate":$RATE,"freeze":"$FREEZE","after":"$AFTER","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
PROM=$(prom_url)
INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId}' --output json)
# busiest_signer <unix s>: the Vault node with the most signs on Consul's intermediate in the minute before.
busiest_signer() {
  prom_query "$PROM" "sum by (instance) (increase(${SIGN_METRIC}[60s]))" "$1" |
    jq -r 'max_by(.value[1] | tonumber) | .metric.instance // empty'
}

restart_consul_agent
T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "T3f Consul's Vault node frozen (run $RUN_ID, $RATE/s)" "perf,t3f,$RUN_ID" "$T1")

stop_k6() { pkill -TERM -f -- "k6 run -e RUN_ID=$RUN_ID -e PERF_NODE=$PERF_NODE " 2>/dev/null || true; }
RAMP=30s HOLD=4h RATE=$RATE K6_CSV_TIME_FORMAT=unix_milli BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/consul-leaf.js --out "csv=$OUT/points.csv" --no-thresholds > "$OUT/k6.log" 2>&1 &
k6_pid=$!
trap stop_k6 EXIT
sleep 150 # ramp, then a minute of steady signing to find Consul's node

node=$(busiest_signer "$(date +%s)")
[ -n "$node" ] || { echo "no signs on Consul's intermediate in Prometheus; is the load running?" >&2; exit 1; }
st=$(vault-raft-voters.sh status)
active=$(jq -r .leader <<<"$st")
iid=$(jq -r --arg n "$node" '.[] | select(.node == $n) | .id' <<<"$INST")
echo "$(date -u +%H:%M:%S) Consul signs through $node (active node: $active); freezing it for $FREEZE"
SID=$(annotate "T3f: SIGSTOP $node" "perf,t3f-step,$RUN_ID")
nlb_watch_start "$iid" "$OUT/nlb.txt"
out=$(ssm_run $((freeze_s + 120)) "pid=\$(pidof vault); t=\$(date +%s%3N); kill -STOP \$pid; sleep $freeze_s; kill -CONT \$pid; echo freeze_ms=\$t" "$iid")
fms=$(grep -o 'freeze_ms=[0-9]*' <<<"$out" | cut -d= -f2)
[ -n "$fms" ] || { echo "freeze failed on $node: $out" >&2; exit 1; }
vault-raft-voters.sh wait-healthy "$(jq -r .voters <<<"$st")" >/dev/null
sleep 30 # the NLB's health checks need ~20-30 s to take the node back
nlb_watch_stop "$OUT/nlb.txt"
annotate_end "$SID"
after_node=$(busiest_signer $((fms / 1000 + 75))) # the minute from freeze + 15 s
idle "t3f after" "$AFTER"
stop_k6
wait "$k6_pid" 2>/dev/null || true
trap - EXIT
T3=$(now_ms)
annotate_end "$AID" "$T3"

client=$(python3 - "$OUT/points.csv" "$fms" "$freeze_s" "$RATE" <<'PY'
import csv, json, sys
pts, f0, freeze, rate = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
end = f0 + (freeze + 60) * 1000
ok, bad = [], []
for row in csv.DictReader(open(pts)):
    if row.get("metric_name") != "http_reqs" or row.get("name") != "leaf":
        continue
    t = float(row["timestamp"])
    t = t if t > 1e11 else t * 1000
    (ok if row.get("status") == "200" else bad).append(t)
ok.sort(); bad.sort()
before = [t for t in ok if t < f0]
around = ([before[-1]] if before else []) + [t for t in ok if f0 <= t <= end]
gaps = [b - a for a, b in zip(around, around[1:])]
fails = [t for t in bad if f0 <= t <= end]
# recovered: the end of the last disrupted 5 s window (any failure, or under
# 90% of RATE succeeding) from the freeze to FREEZE + 60 s; 0 if none was.
rec, w = 0, 5
for s0 in range(0, (end - f0) // 1000, w):
    a, b = f0 + s0 * 1000, f0 + (s0 + w) * 1000
    if any(a <= t < b for t in fails) or sum(1 for t in ok if a <= t < b) < 0.9 * rate * w:
        rec = s0 + w
print(json.dumps({"failed_leafs": len(fails),
                  "error_window_s": round((fails[-1] - fails[0]) / 1000, 2) if fails else 0,
                  "max_gap_s": round(max(gaps) / 1000, 2) if gaps else None,
                  "recovered_s": rec}))
PY
) || client='{}'
gzip -f "$OUT/points.csv"
jq -n --arg node "$node" --arg active "$active" --arg after "${after_node:-}" --argjson rate "$RATE" --arg freeze "$FREEZE" \
  --argjson c "${client:-{\}}" --argjson nlb "$(nlb_watch_summary "$OUT/nlb.txt" "$fms")" \
  '{rate: $rate, freeze: $freeze, frozen_node: $node, frozen_was_active: ($node == $active), nlb: $nlb,
    signer_after: (if $after == "" then null else $after end), moved: ($after != "" and $after != $node)} + $c' > "$OUT/t3f.json"
jq -c . "$OUT/t3f.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)
jq -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson f "$fms" --argjson fe $((fms + (freeze_s + 60) * 1000)) \
  --argjson t3 "$T3" --argjson t4 "$T4" \
  '[{name: "baseline", start: $t0, end: $t1}, {name: "freeze", start: $f, end: $fe}, {name: "cooldown", start: $t3, end: $t4}]
   | map(select(.end > .start))' > "$OUT/phases.json"
# export_grafana exports lib.sh's PHASES (and rewrites phases.json from it).
PHASES=$(jq -c . "$OUT/phases.json")
export_grafana "$OUT" "T3f Consul's Vault node frozen ($RUN_ID)"
upload_results "$OUT"
