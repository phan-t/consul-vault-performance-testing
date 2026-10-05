#!/bin/bash
# T11 failover: how long Vault writes stop when the active node hangs.
#   RUN_ID=t11v5-failover vault-failover-test.sh
#
# Under a light constant write load (vault-kv-write.js at RATE, default 20/s,
# through the NLB), REPEATS times (default 3; election timing is randomised):
#   1. freeze the active node's vault process with SIGSTOP for FREEZE (60s),
#      over SSM - a hung or crashed leader; the same command sends SIGCONT, so
#      the node always comes back even if this script dies
#   2. poll every other voter's /v1/sys/health until one answers 200 (active)
#   3. after SIGCONT, wait for Autopilot healthy with the full voter set, then GAP
# Per repeat it records:
#   new_active_s  freeze -> another node active (election + post-unseal setup)
#   write_gap_s   longest gap between successful writes around the freeze: how
#                 long no client could write (requests the NLB sends to the frozen
#                 node hang until REQ_TIMEOUT, 10s, and count as failures)
#   failed_writes failed or timed-out writes from the freeze to FREEZE + 60s
#   healthy_s     freeze -> Autopilot healthy again (coarse: +-10s of SSM polling)
# and, from every voter's Vault log (journald, freeze - 15s to healthy + 5s,
# fetched over SSM into logs/repeat-<i>/<node>.log), the leadership timeline in
# logs/repeat-<i>/timeline.log and its stages (failover-logs.py): detected_s
# (a follower's heartbeat timeout), elected_s (election won), active_s (new
# active node's post-unseal setup complete), old_stepdown_s (after SIGCONT).
# SSM returns at most 24,000 characters per node, so each log is sent gzipped;
# a window too large even then is reduced to its leadership lines (noted at the
# top of the file). Node clocks are NTP-synced (Amazon Time Sync).
# Writes <RUN_ID>-<node>-failover/failover.json and points.csv.gz (k6 per request).
# Needs kv_perf/ (kv-perf-mount.sh create) and SSM Run Command on the Vault nodes.
. /opt/perf/scripts/lib.sh

REPEATS=${REPEATS:-3}
RATE=${RATE:-20}
FREEZE=${FREEZE:-60s} # must outlast detection + election (8-11 s in the raft-1 run)
GAP=${GAP:-60s}
REQ_TIMEOUT=${REQ_TIMEOUT:-10s}
freeze_s=$(to_secs "$FREEZE")

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-failover"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"vault-failover-test","run_id":"$RUN_ID","node":"$PERF_NODE","repeats":$REPEATS,"rate":$RATE,"freeze":"$FREEZE","gap":"$GAP","req_timeout":"$REQ_TIMEOUT","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
kv-perf-mount.sh create >/dev/null
echo '[]' > "$OUT/repeats.json"

# Vault instances: node -> {id, ip}
INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId, ip: PrivateIpAddress}' --output json)

# poll_active <exclude node> <voter nodes...>: print "<ms> <node>" when another voter is active.
poll_active() {
  local skip=$1 n ip deadline=$(($(date +%s) + 180))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    for n in "$@"; do
      [ "$n" = "$skip" ] && continue
      ip=$(jq -r --arg n "$n" '.[] | select(.node == $n) | .ip' <<<"$INST")
      if [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 1 "https://$ip:8200/v1/sys/health")" = 200 ]; then
        echo "$(now_ms) $n"
        return
      fi
    done
    sleep 0.2
  done
  echo "null null"
}

# fetch_logs <dir> <since s> <until s> <node...>: each node's Vault log for the window -> <dir>/<node>.log
LOG_PATTERN='heartbeat|vote|candidate|election|leader|follower|failed to contact|acquired lock|active operation|post-unseal|pre-seal|step.?down|standby'
fetch_logs() {
  local d=$1 since=$2 until=$3 n id cid st cmd tries
  shift 3
  mkdir -p "$d"
  cmd="journalctl -u vault --since @$since --until @$until -o short-iso-precise --no-pager -q > /tmp/vl
if [ \$(gzip -9c /tmp/vl | base64 -w0 | wc -c) -gt 23000 ]; then
  { echo '# filtered to leadership lines: the full window was too large for SSM output'; grep -iE '$LOG_PATTERN' /tmp/vl | tail -n 2000; } > /tmp/vl2 && mv /tmp/vl2 /tmp/vl
fi
gzip -9c /tmp/vl | base64 -w0; rm -f /tmp/vl"
  local ids=()
  for n in "$@"; do ids+=("$(jq -r --arg n "$n" '.[] | select(.node == $n) | .id' <<<"$INST")"); done
  cid=$(aws ssm send-command --instance-ids "${ids[@]}" --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$cmd" '{commands: [$c], executionTimeout: ["120"]}')" \
    --comment "perf $RUN_ID logs" --query Command.CommandId --output text) || { echo "log fetch: send-command failed" >&2; return 0; }
  for n in "$@"; do
    id=$(jq -r --arg n "$n" '.[] | select(.node == $n) | .id' <<<"$INST")
    tries=0
    while :; do
      st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
      tries=$((tries + 1)); [ "$tries" -gt 60 ] && break
      sleep 3
    done
    aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null |
      base64 -d 2>/dev/null | gunzip > "$d/$n.log" 2>/dev/null || echo "# log fetch failed on $n (SSM status $st)" > "$d/$n.log"
  done
}

T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "T11 failover (run $RUN_ID, $REPEATS x SIGSTOP active node for $FREEZE)" "perf,failover,$RUN_ID" "$T1")

# Through run-k6.sh like every k6 run (client metrics to Prometheus, memory
# guard), with a long HOLD; stopped with SIGTERM once the repeats are done.
# The per-request CSV is an extra output for the write-gap analysis.
stop_k6() { pkill -TERM -f -- "k6 run -e RUN_ID=$RUN_ID -e PERF_NODE=$PERF_NODE " 2>/dev/null || true; }
RAMP=10s HOLD=4h RATE=$RATE REQ_TIMEOUT=$REQ_TIMEOUT K6_CSV_TIME_FORMAT=unix_milli BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/vault-kv-write.js --out "csv=$OUT/points.csv" --no-thresholds > "$OUT/k6.log" 2>&1 &
k6_pid=$!
trap stop_k6 EXIT
sleep 40 # ramp + steady writes before the first freeze

PHASE_LIST="[]"
for i in $(seq 1 "$REPEATS"); do
  st=$(vault-raft-voters.sh status)
  old=$(jq -r .leader <<<"$st"); voters=$(jq -r .voters <<<"$st")
  iid=$(jq -r --arg n "$old" '.[] | select(.node == $n) | .id' <<<"$INST")
  echo "$(date -u +%H:%M:%S) repeat $i/$REPEATS: freezing active node $old ($iid) for $FREEZE"
  SID=$(annotate "failover $i: SIGSTOP $old" "perf,failover-step,$RUN_ID")
  poll_active "$old" $(jq -r '.voter_nodes[]' <<<"$st") > "$OUT/active.$i" &
  poll_pid=$!
  out=$(ssm_run $((freeze_s + 120)) "pid=\$(pidof vault); t=\$(date +%s%3N); kill -STOP \$pid; sleep $freeze_s; kill -CONT \$pid; echo freeze_ms=\$t" "$iid")
  wait "$poll_pid" || true
  fms=$(grep -o 'freeze_ms=[0-9]*' <<<"$out" | cut -d= -f2)
  [ -n "$fms" ] || { echo "freeze failed on $old: $out" >&2; exit 1; }
  vault-raft-voters.sh wait-healthy "$voters" >/dev/null
  hms=$(now_ms)
  annotate_end "$SID"
  read -r ams new < "$OUT/active.$i"
  rm -f "$OUT/active.$i"
  sleep 5
  ldir="$OUT/logs/repeat-$i"
  fetch_logs "$ldir" $((fms / 1000 - 15)) $((hms / 1000 + 5)) $(jq -r '.voter_nodes[]' <<<"$st")
  lg=$(python3 /opt/perf/scripts/failover-logs.py "$ldir" "$fms" "$old" || echo '{}')
  r=$(jq -n -c --argjson i "$i" --arg old "$old" --arg new "$new" --argjson f "$fms" --arg a "$ams" --argjson h "$hms" --argjson lg "$lg" \
    '$lg + {repeat: $i, old_active: $old, new_active: (if $new == "null" then null else $new end), freeze_ms: $f,
      new_active_s: (if $a == "null" then null else (($a | tonumber) - $f) / 1000 end), healthy_s: (($h - $f) / 1000)}')
  echo "  $r"
  jq --argjson r "$r" '. + [$r]' "$OUT/repeats.json" > "$OUT/repeats.tmp" && mv "$OUT/repeats.tmp" "$OUT/repeats.json"
  PHASE_LIST=$(jq -c --argjson i "$i" --argjson s "$fms" --argjson e "$hms" '. + [{name: "failover-\($i)", start: $s, end: $e}]' <<<"$PHASE_LIST")
  idle "failover gap" "$GAP"
done

stop_k6
wait "$k6_pid" 2>/dev/null || true
trap - EXIT
T3=$(now_ms)
annotate_end "$AID" "$T3"

# Client view from k6's per-request samples (http_reqs, one row per request, ms timestamps).
python3 - "$OUT/points.csv" "$OUT/repeats.json" "$freeze_s" > "$OUT/repeats.tmp" <<'PY'
import csv, json, sys
pts, reps, freeze = sys.argv[1], json.load(open(sys.argv[2])), int(sys.argv[3])
ok, bad = [], []
for row in csv.DictReader(open(pts)):
    if row.get("metric_name") != "http_reqs" or row.get("name") != "kv_write":
        continue
    t = float(row["timestamp"])
    t = t if t > 1e11 else t * 1000  # unix seconds if K6_CSV_TIME_FORMAT was ignored
    (ok if row.get("status") == "200" else bad).append(t)
ok.sort()
for r in reps:
    f, end = r["freeze_ms"], r["freeze_ms"] + (freeze + 60) * 1000
    before = [t for t in ok if t < f]
    around = ([before[-1]] if before else []) + [t for t in ok if f <= t <= end]
    gaps = [b - a for a, b in zip(around, around[1:])]
    r["write_gap_s"] = round(max(gaps) / 1000, 2) if gaps else None
    r["failed_writes"] = sum(1 for t in bad if f <= t <= end)
print(json.dumps(reps))
PY
gzip -f "$OUT/points.csv"

jq --argjson n "$(vault-raft-voters.sh status | jq .voters)" '. as $r
  | def stat(k): ([$r[][k] | select(. != null)] | sort) as $v
      | if ($v | length) == 0 then null else {median: $v[($v | length) / 2 | floor], max: $v[-1]} end;
  {voters: $n, repeats: $r, new_active_s: stat("new_active_s"), write_gap_s: stat("write_gap_s"),
   healthy_s: stat("healthy_s"), detected_s: stat("detected_s"), elected_s: stat("elected_s"),
   active_s: stat("active_s"), old_stepdown_s: stat("old_stepdown_s"), failed_writes: ([$r[].failed_writes] | add)}' "$OUT/repeats.tmp" > "$OUT/failover.json"
rm -f "$OUT/repeats.tmp" "$OUT/repeats.json"
jq -c '{voters, detected_s, elected_s, active_s, new_active_s, write_gap_s, failed_writes}' "$OUT/failover.json"
for t in "$OUT"/logs/repeat-*/timeline.log; do [ -f "$t" ] && { echo "--- $t"; cat "$t"; }; done

idle cooldown "$COOLDOWN"
T4=$(now_ms)
PHASES=$(jq -c -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson t3 "$T3" --argjson t4 "$T4" --argjson f "$PHASE_LIST" \
  '[{name: "baseline", start: $t0, end: $t1}] + $f + [{name: "cooldown", start: $t3, end: $t4}] | map(select(.end > .start))')
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "T11 failover ($RUN_ID)"
upload_results "$OUT"
