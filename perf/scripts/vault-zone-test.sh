#!/bin/bash
# T12: Autopilot redundancy zones under load (DBS scenario 4, the HLD's design:
# one voter per zone, non-voter spares added as scale demands).
#   RUN_ID=t12 RATE=3200 vault-zone-test.sh
#
# Under a constant signing load (vault-sign-consul-mount.js at RATE through the
# NLB), it picks a zone with a spare, then:
#   MODE=standby (default): a zone whose voter isn't the active node, other than
#                EXCLUDE_ZONE if possible (repeats alternate zones)
#   MODE=active: the active node's zone, so the freeze also forces an election
#                (election plus promotion: the realistic worst case)
#   1. join:    re-adds that spare from scratch (stop, remove-peer, wipe its Raft
#               data, start), as when a spare is added for scale, and times
#               joined_s (it appears in Autopilot's server list) and healthy_s
#               (Autopilot healthy). It should stay a non-voter: its zone has a voter.
#   2. failure: freezes the zone's voter with SIGSTOP (a hung node: unplanned),
#               and times unhealthy_s (Autopilot marks it unhealthy),
#               promoted_s (the spare is a voter), demoted_s (the frozen voter
#               is a non-voter) and restored_s (failure tolerance back to where
#               it was). The voter is thawed (SIGCONT) THAW_AFTER (30s) after
#               restored, or after FREEZE_MAX (300s) if that never happens, then
#               recovered_s is when Autopilot is healthy again.
# The NLB's view of the frozen voter is polled every 2 s (failure.nlb: out_s,
# back_s): requests reach the frozen node until the NLB marks it unhealthy.
# Times are seconds from the start command (join) or the freeze (failure),
# polled every second. Client view per phase, from k6's per-request samples:
# failed requests, the error window (first to last failure) and the longest gap
# between successful requests. Requests the NLB sends to the frozen node hang
# until k6's 30 s timeout, so the error window includes NLB health checks.
# Writes <RUN_ID>-<node>-zones/zones.json, points.csv.gz, phases.json.
# Needs a build with vault_redundancy_zones (and its spares in Raft: run after
# T9-V) and SSM Run Command on the Vault nodes.
. /opt/perf/scripts/lib.sh

RATE=${RATE:-1600}
FREEZE_MAX=${FREEZE_MAX:-300s}
THAW_AFTER=${THAW_AFTER:-30s}
SETTLE=${SETTLE:-60s}
freeze_max_s=$(to_secs "$FREEZE_MAX")

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-zones"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"vault-zone-test","run_id":"$RUN_ID","node":"$PERF_NODE","rate":$RATE,"freeze_max":"$FREEZE_MAX","thaw_after":"$THAW_AFTER","settle":"$SETTLE","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P

INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId, ip: PrivateIpAddress}' --output json)
iid() { jq -r --arg n "$1" '.[] | select(.node == $n) | .id' <<<"$INST"; }
ipof() { jq -r --arg n "$1" '.[] | select(.node == $n) | .ip' <<<"$INST"; }

# Autopilot state, keys normalised (lower case, no underscores), from a voter
# that won't be frozen (POLL_IP) directly: through the NLB a poll could land on
# the frozen node and hang. Standbys forward the request to the active node, so
# during an election (MODE=active) polls fail for a few seconds and are retried.
# The TLS certificate names the NLB host, not node IPs, hence the server name.
TLS_NAME=${VAULT_ADDR#https://}
TLS_NAME=${TLS_NAME%%:*}
POLL_IP=""
ap() {
  local out=""
  if [ -n "$POLL_IP" ]; then
    out=$(VAULT_ADDR="https://$POLL_IP:8200" VAULT_TLS_SERVER_NAME="$TLS_NAME" VAULT_CLIENT_TIMEOUT=3s \
      vault operator raft autopilot state -format=json 2>/dev/null) || out=""
  fi
  [ -n "$out" ] || out=$(VAULT_CLIENT_TIMEOUT=3s vault operator raft autopilot state -format=json 2>/dev/null) || return 1
  jq -c 'walk(if type == "object" then with_entries(.key |= (ascii_downcase | gsub("_"; ""))) else . end)
    | {healthy, ft: .failuretolerance,
       servers: [.servers // {} | to_entries[] | {node: .key, zone: (.value.redundancyzone // ""),
         status: .value.status, healthy: .value.healthy}]}' <<<"$out"
}
srv() { jq -c --arg n "$2" '.servers[] | select(.node == $n)' <<<"$1"; } # srv <state> <node>
is_voter() { jq -e '.status == "voter" or .status == "leader"' >/dev/null 2>&1 <<<"${1:-null}"; }

MODE=${MODE:-standby}
EXCLUDE_ZONE=${EXCLUDE_ZONE:-}
st=$(vault-raft-voters.sh status)
leader=$(jq -r .leader <<<"$st")
POLL_IP=$(ipof "$leader")
a=$(ap) || { echo "can't read Autopilot state" >&2; exit 1; }
ft0=$(jq -r .ft <<<"$a")
pick=$(jq -c --arg l "$leader" --arg mode "$MODE" --arg ex "$EXCLUDE_ZONE" '.servers as $s
  | [$s[] | select(.status == "non-voter" and .zone != "") | .zone as $z
     | {spare: .node, zone: $z,
        voter: ([$s[] | select(.zone == $z and (.status == "voter" or .status == "leader")) | .node] | first)}]
  | map(select(.voter != null and (if $mode == "active" then .voter == $l else .voter != $l end)))
  | (map(select(.zone != $ex)) + .) | first // empty' <<<"$a")
if [ -z "$pick" ]; then
  echo "MODE=$MODE: no redundancy zone with a spare and a suitable voter (active node $leader); zones: $(jq -c '[.servers[] | {node, zone, status}]' <<<"$a")" >&2
  exit 3 # no suitable zone: the caller records a skip
fi
SPARE=$(jq -r .spare <<<"$pick"); VOTER=$(jq -r .voter <<<"$pick"); ZONE=$(jq -r .zone <<<"$pick")
# Poll through a voter that won't be frozen.
POLL_IP=$(ipof "$(jq -r --arg v "$VOTER" '[.voter_nodes[] | select(. != $v)] | first' <<<"$st")")
echo "$(date -u +%H:%M:%S) MODE=$MODE zone $ZONE: voter $VOTER, spare $SPARE (active node $leader, failure tolerance $ft0)"

T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "T12 redundancy zones (run $RUN_ID): re-add $SPARE, freeze $VOTER" "perf,zones,$RUN_ID" "$T1")

# Through run-k6.sh like every k6 run, with a long HOLD; stopped with SIGTERM at the end.
stop_k6() { pkill -TERM -f -- "k6 run -e RUN_ID=$RUN_ID -e PERF_NODE=$PERF_NODE " 2>/dev/null || true; }
RAMP=30s HOLD=4h RATE=$RATE K6_CSV_TIME_FORMAT=unix_milli BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/vault-sign-consul-mount.js --out "csv=$OUT/points.csv" --no-thresholds > "$OUT/k6.log" 2>&1 &
k6_pid=$!
trap 'stop_k6; ssm_run 60 "touch /tmp/zt-thaw" "$(iid "$VOTER")" >/dev/null 2>&1' EXIT
sleep 90 # ramp, then steady load before the join

# --- 1. join: re-add the spare from scratch -----------------------------------
sid=$(iid "$SPARE")
ssm_run 120 'systemctl disable --now vault && echo stopped' "$sid"
vault_retry vault operator raft remove-peer "$SPARE"
sleep 10 # Autopilot drops it from its server list
j0=$(now_ms)
ssm_run 300 'set -e
find /opt/vault/data -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
systemctl enable --now vault && echo started' "$sid" > "$OUT/join.ssm" &
jbg=$!
jt='{}'
for i in $(seq 1 600); do
  sleep 1
  a=$(ap) || continue
  now=$(now_ms)
  s=$(srv "$a" "$SPARE")
  [ -n "$s" ] && jt=$(jq -c --argjson n "$now" '.joined_ms //= $n' <<<"$jt")
  jq -e '.healthy == true' >/dev/null 2>&1 <<<"$s" && jt=$(jq -c --argjson n "$now" '.healthy_ms //= $n' <<<"$jt")
  is_voter "$s" && jt=$(jq -c --argjson n "$now" '.promoted_ms //= $n' <<<"$jt")
  # Done 60 s after it's healthy: long enough to see it stay a non-voter.
  h=$(jq -r '.healthy_ms // empty' <<<"$jt")
  [ -n "$h" ] && [ $((now - h)) -ge 60000 ] && { jt=$(jq -c --arg s "$(jq -r .status <<<"$s")" '.status_after = $s' <<<"$jt"); break; }
done
wait "$jbg" || true
j1=$(now_ms)
jt=$(jq -c --argjson t0 "$j0" 'def s(k): if .[k] then (.[k] - $t0) / 1000 else null end;
  {joined_s: s("joined_ms"), healthy_s: s("healthy_ms"), promoted_s: s("promoted_ms"), status_after: (.status_after // null)}' <<<"$jt")
echo "  join: $jt"
idle "zone settle" "$SETTLE"

# --- 2. failure: freeze the zone's voter --------------------------------------
vid=$(iid "$VOTER")
nlb_watch_start "$vid" "$OUT/nlb.txt"
ssm_run $((freeze_max_s + 120)) "rm -f /tmp/zt-thaw; pid=\$(pidof vault); echo freeze_ms=\$(date +%s%3N); kill -STOP \$pid
i=0; while [ \$i -lt $freeze_max_s ] && [ ! -f /tmp/zt-thaw ]; do sleep 1; i=\$((i + 1)); done
kill -CONT \$pid; echo thaw_ms=\$(date +%s%3N)" "$vid" > "$OUT/freeze.ssm" &
fbg=$!
ft='{}'
thaw_sent=""
for i in $(seq 1 $((freeze_max_s + 60))); do
  sleep 1
  kill -0 "$fbg" 2>/dev/null || break # thawed (FREEZE_MAX reached)
  a=$(ap) || continue
  now=$(now_ms)
  v=$(srv "$a" "$VOTER"); s=$(srv "$a" "$SPARE")
  jq -e '.healthy == false' >/dev/null 2>&1 <<<"$v" && ft=$(jq -c --argjson n "$now" '.unhealthy_ms //= $n' <<<"$ft")
  is_voter "$s" && ft=$(jq -c --argjson n "$now" '.promoted_ms //= $n' <<<"$ft")
  jq -e '.status == "non-voter"' >/dev/null 2>&1 <<<"$v" && ft=$(jq -c --argjson n "$now" '.demoted_ms //= $n' <<<"$ft")
  if jq -e '.promoted_ms' >/dev/null <<<"$ft" && [ "$(jq -r '.ft // 0' <<<"$a")" -ge "$ft0" ]; then
    ft=$(jq -c --argjson n "$now" '.restored_ms //= $n' <<<"$ft")
  fi
  r=$(jq -r '.restored_ms // empty' <<<"$ft")
  if [ -n "$r" ] && [ -z "$thaw_sent" ] && [ $((now - r)) -ge $(($(to_secs "$THAW_AFTER") * 1000)) ]; then
    ssm_run 60 'touch /tmp/zt-thaw' "$vid" >/dev/null; thaw_sent=1
  fi
done
wait "$fbg" || true
fms=$(grep -o 'freeze_ms=[0-9]*' "$OUT/freeze.ssm" | cut -d= -f2)
tms=$(grep -o 'thaw_ms=[0-9]*' "$OUT/freeze.ssm" | cut -d= -f2)
[ -n "$fms" ] || { echo "freeze failed on $VOTER: $(cat "$OUT/freeze.ssm")" >&2; exit 1; }
# Recovery: Autopilot healthy, failure tolerance back.
rms=""
for i in $(seq 1 600); do
  a=$(ap) && [ "$(jq -r .healthy <<<"$a")" = true ] && [ "$(jq -r '.ft // 0' <<<"$a")" -ge "$ft0" ] && { rms=$(now_ms); break; }
  sleep 1
done
f1=$(now_ms)
nlb_watch_stop "$OUT/nlb.txt"
layout=$(jq -c '[.servers[] | {node, zone, status}] | sort_by(.zone, .node)' <<<"${a:-{\}}")
ft=$(jq -c --argjson t0 "$fms" --argjson th "${tms:-null}" --argjson rc "${rms:-null}" \
  --arg vf "$(jq -r --arg n "$VOTER" '.[] | select(.node == $n) | .status' <<<"$layout")" '
  def s(k): if .[k] then (.[k] - $t0) / 1000 else null end;
  {unhealthy_s: s("unhealthy_ms"), promoted_s: s("promoted_ms"), demoted_s: s("demoted_ms"), restored_s: s("restored_ms"),
   thaw_s: (if $th then ($th - $t0) / 1000 else null end), recovered_s: (if $rc then ($rc - $t0) / 1000 else null end),
   frozen_voter_after: $vf}' <<<"$ft")
ft=$(jq -c --argjson nlb "$(nlb_watch_summary "$OUT/nlb.txt" "$fms")" '. + {nlb: $nlb}' <<<"$ft")
echo "  failure: $ft"

stop_k6
wait "$k6_pid" 2>/dev/null || true
ssm_run 60 'touch /tmp/zt-thaw' "$vid" >/dev/null 2>&1 || true
trap - EXIT
T3=$(now_ms)
annotate_end "$AID" "$T3"

# Client view per phase from k6's per-request samples.
client=$(python3 - "$OUT/points.csv" "$j0" "$j1" "$fms" "$f1" <<'PY'
import csv, json, sys
pts, j0, j1, f0, f1 = sys.argv[1], *map(int, sys.argv[2:])
ok, bad = [], []
for row in csv.DictReader(open(pts)):
    if row.get("metric_name") != "http_reqs" or row.get("name") != "sign":
        continue
    t = float(row["timestamp"])
    t = t if t > 1e11 else t * 1000
    (ok if row.get("status") == "200" else bad).append(t)
ok.sort(); bad.sort()
def phase(a, b):
    o = [t for t in ok if a <= t <= b]
    f = [t for t in bad if a <= t <= b]
    gaps = [y - x for x, y in zip(o, o[1:])]
    return {"requests": len(o) + len(f), "failed": len(f),
            "error_window_s": round((f[-1] - f[0]) / 1000, 2) if f else 0,
            "max_gap_s": round(max(gaps) / 1000, 2) if gaps else None}
print(json.dumps({"join": phase(j0, j1), "failure": phase(f0, f1)}))
PY
) || client='{}'
gzip -f "$OUT/points.csv"

jq -n --arg zone "$ZONE" --arg voter "$VOTER" --arg spare "$SPARE" --arg leader "$leader" --argjson rate "$RATE" \
  --argjson ft0 "$ft0" --argjson j "$jt" --argjson f "$ft" --argjson c "${client:-{\}}" --argjson layout "$layout" \
  --arg mode "$MODE" '{mode: $mode, rate: $rate, zone: $zone, voter: $voter, spare: $spare, active_node: $leader, failure_tolerance: $ft0,
    join: ($j + {client: $c.join}), failure: ($f + {client: $c.failure}), layout_after: $layout}' > "$OUT/zones.json"
jq -c '{zone, voter, spare, join, failure}' "$OUT/zones.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)
PHASES=$(jq -c -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson j0 "$j0" --argjson j1 "$j1" --argjson f0 "$fms" \
  --argjson f1 "$f1" --argjson t3 "$T3" --argjson t4 "$T4" \
  '[{name: "baseline", start: $t0, end: $t1}, {name: "join", start: $j0, end: $j1},
    {name: "zone-failure", start: $f0, end: $f1}, {name: "cooldown", start: $t3, end: $t4}] | map(select(.end > .start))')
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "T12 redundancy zones ($RUN_ID)"
upload_results "$OUT"
