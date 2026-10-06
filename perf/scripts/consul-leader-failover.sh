#!/bin/bash
# T14: what sidecars see when the Consul leader hangs.
#   RUN_ID=t14 RATE=350 consul-leader-failover.sh
#
# Every CSR is signed on the Consul leader, through its Vault CA provider. A new
# leader must set up its own provider (Vault login, connection) before it signs
# anything, so leafs may stall for longer than the election alone. Under a
# constant leaf load through Consul (consul-leaf.js at RATE; remove Consul's
# CSR limits first), REPEATS times (default 3; election timing is random):
#   1. freeze the Consul leader with SIGSTOP for FREEZE (60s), then SIGCONT;
#   2. poll the local agent's /v1/status/leader until another server leads;
#   3. wait for Consul's Autopilot to be healthy, then GAP (60s).
# Per repeat, over the freeze to FREEZE + 60 s:
#   new_leader_s   freeze -> another server is leader (polled every 0.5 s)
#   max_gap_s      longest gap between successful leafs
#   failed_leafs   failed or timed-out leaf requests (k6 timeout 60 s)
#   recovered_s    freeze -> end of the last disrupted 5 s window (a failure,
#                  or under 90% of RATE succeeding)
#   first_leaf_after_leader_s  new leader -> the first successful leaf after the
#                  gap: the cost of the new leader's CA provider setup
# Writes <RUN_ID>-<node>-t14/t14.json, points.csv.gz, phases.json.
. /opt/perf/scripts/lib.sh
export CONSUL_HTTP_TOKEN="$CONSUL_OPERATOR_TOKEN"

RATE=${RATE:-350}
REPEATS=${REPEATS:-3}
FREEZE=${FREEZE:-60s}
GAP=${GAP:-60s}
freeze_s=$(to_secs "$FREEZE")
ADDR=${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-t14"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"consul-leader-failover","run_id":"$RUN_ID","node":"$PERF_NODE","rate":$RATE,"repeats":$REPEATS,"freeze":"$FREEZE","gap":"$GAP","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=consul" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId, ip: PrivateIpAddress}' --output json)
leader_ip() { curl -sf --max-time 1 "$ADDR/v1/status/leader" | tr -d '"' | cut -d: -f1; }
consul_healthy() { curl -sf --max-time 2 -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$ADDR/v1/operator/autopilot/health" | jq -e '.Healthy' >/dev/null; }

restart_consul_agent
T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "T14 Consul leader frozen (run $RUN_ID, $RATE/s, $REPEATS x)" "perf,t14,$RUN_ID" "$T1")

stop_k6() { pkill -TERM -f -- "k6 run -e RUN_ID=$RUN_ID -e PERF_NODE=$PERF_NODE " 2>/dev/null || true; }
RAMP=30s HOLD=4h RATE=$RATE K6_CSV_TIME_FORMAT=unix_milli BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/consul-leaf.js --out "csv=$OUT/points.csv" --no-thresholds > "$OUT/k6.log" 2>&1 &
k6_pid=$!
trap stop_k6 EXIT
sleep 120 # ramp, then steady leafs

reps='[]'
PHASE_LIST='[]'
for i in $(seq 1 "$REPEATS"); do
  lip=$(leader_ip)
  node=$(jq -r --arg ip "$lip" '.[] | select(.ip == $ip) | .node' <<<"$INST")
  iid=$(jq -r --arg ip "$lip" '.[] | select(.ip == $ip) | .id' <<<"$INST")
  [ -n "$iid" ] || { echo "can't map the Consul leader ($lip) to an instance" >&2; exit 1; }
  echo "$(date -u +%H:%M:%S) repeat $i/$REPEATS: freezing Consul leader $node ($iid) for $FREEZE"
  SID=$(annotate "T14 $i: SIGSTOP Consul leader $node" "perf,t14-step,$RUN_ID")
  ssm_run $((freeze_s + 120)) "pid=\$(pidof consul); echo freeze_ms=\$(date +%s%3N); kill -STOP \$pid; sleep $freeze_s; kill -CONT \$pid" "$iid" > "$OUT/freeze.$i" &
  fbg=$!
  nl=null; nl_node=null
  for _ in $(seq 1 $((freeze_s * 2))); do
    sleep 0.5
    cur=$(leader_ip || true)
    if [ -n "$cur" ] && [ "$cur" != "$lip" ]; then
      nl=$(now_ms); nl_node=$(jq -r --arg ip "$cur" '.[] | select(.ip == $ip) | .node' <<<"$INST"); break
    fi
  done
  wait "$fbg" || true
  fms=$(grep -o 'freeze_ms=[0-9]*' "$OUT/freeze.$i" | cut -d= -f2)
  [ -n "$fms" ] || { echo "freeze failed on $node: $(cat "$OUT/freeze.$i")" >&2; exit 1; }
  for _ in $(seq 1 120); do consul_healthy && break; sleep 5; done
  hms=$(now_ms)
  annotate_end "$SID"
  reps=$(jq -c --argjson i "$i" --arg old "$node" --arg new "$nl_node" --argjson f "$fms" --argjson nl "$nl" --argjson h "$hms" \
    '. + [{repeat: $i, old_leader: $old, new_leader: (if $new == "null" then null else $new end), freeze_ms: $f, new_leader_ms: $nl,
           new_leader_s: (if $nl then ($nl - $f) / 1000 else null end), healthy_s: (($h - $f) / 1000)}]' <<<"$reps")
  PHASE_LIST=$(jq -c --argjson i "$i" --argjson s "$fms" --argjson e "$hms" '. + [{name: "leader-freeze-\($i)", start: $s, end: $e}]' <<<"$PHASE_LIST")
  idle "t14 gap" "$GAP"
done

stop_k6
wait "$k6_pid" 2>/dev/null || true
trap - EXIT
T3=$(now_ms)
annotate_end "$AID" "$T3"

echo "$reps" > "$OUT/repeats.in.json"
python3 - "$OUT/points.csv" "$freeze_s" "$RATE" "$OUT/repeats.in.json" > "$OUT/repeats.json" <<'PY'
import csv, json, sys
pts, freeze, rate = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
reps = json.load(open(sys.argv[4]))
ok, bad = [], []
for row in csv.DictReader(open(pts)):
    if row.get("metric_name") != "http_reqs" or row.get("name") != "leaf":
        continue
    t = float(row["timestamp"]); t = t if t > 1e11 else t * 1000
    (ok if row.get("status") == "200" else bad).append(t)
ok.sort(); bad.sort()
for r in reps:
    f0 = r["freeze_ms"]; end = f0 + (freeze + 60) * 1000
    before = [t for t in ok if t < f0]
    around = ([before[-1]] if before else []) + [t for t in ok if f0 <= t <= end]
    gaps = [(b - a, a, b) for a, b in zip(around, around[1:])]
    big = max(gaps) if gaps else None
    fails = [t for t in bad if f0 <= t <= end]
    rec, w = 0, 5
    for s0 in range(0, (end - f0) // 1000, w):
        a, b = f0 + s0 * 1000, f0 + (s0 + w) * 1000
        if any(a <= t < b for t in fails) or sum(1 for t in ok if a <= t < b) < 0.9 * rate * w:
            rec = s0 + w
    r["max_gap_s"] = round(big[0] / 1000, 2) if big else None
    r["failed_leafs"] = len(fails)
    r["recovered_s"] = rec
    nl = r.get("new_leader_ms")
    after = [t for t in ok if nl and t >= nl]
    r["first_leaf_after_leader_s"] = round((after[0] - nl) / 1000, 2) if after else None
print(json.dumps(reps))
PY
gzip -f "$OUT/points.csv"
jq '. as $r | def stat(k): ([$r[][k] | select(. != null)] | sort) as $v
    | if ($v | length) == 0 then null else {median: $v[($v | length) / 2 | floor], min: $v[0], max: $v[-1]} end;
  {repeats: $r, new_leader_s: stat("new_leader_s"), max_gap_s: stat("max_gap_s"), recovered_s: stat("recovered_s"),
   first_leaf_after_leader_s: stat("first_leaf_after_leader_s"), failed_leafs: ([$r[].failed_leafs] | add)}' \
  "$OUT/repeats.json" > "$OUT/t14.json"
rm -f "$OUT/repeats.json" "$OUT/repeats.in.json" "$OUT"/freeze.*
jq -c '{new_leader_s, max_gap_s, recovered_s, first_leaf_after_leader_s, failed_leafs}' "$OUT/t14.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)
jq -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson t3 "$T3" --argjson t4 "$T4" --argjson f "$PHASE_LIST" \
  '[{name: "baseline", start: $t0, end: $t1}] + $f + [{name: "cooldown", start: $t3, end: $t4}] | map(select(.end > .start))' > "$OUT/phases.json"
export_grafana "$OUT" "T14 Consul leader frozen ($RUN_ID)"
upload_results "$OUT"
