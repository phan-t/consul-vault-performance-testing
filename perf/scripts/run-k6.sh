#!/bin/bash
# Usage: run-k6.sh <script.js>
#   RATE=200 run-k6.sh /opt/perf/k6/consul-leaf.js
#   RATE=500 run-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
#   COUNT=5000 RATE=100 run-k6.sh /opt/perf/k6/consul-register-burst.js
#
# Timeline: BASELINE (5m idle) -> RAMP (2m warm-up) -> HOLD (10m steady)
#           -> COOLDOWN (5m idle), then a Grafana export of the whole window.
# The burst script has no ramp: its whole run is the "steady" phase.
# RATE is per load generator; use run-everywhere.sh with one RUN_ID to fan out.
#
# Load generator memory guard: the Consul client agent caches every leaf that
# consul-leaf.js fetches (about 12 KB each, new service name per request), so at
# high rates the load generator's memory drains within one step. In plan-1 it
# ran out at 6,400/s, thrashed and went dark for 28 minutes, which failed the
# step and set off a Consul leader election. While k6 runs, the guard samples
# MemAvailable every 5 s; below MEM_GUARD_PCT (default 10%) it stops k6 with
# SIGTERM (k6 stops gracefully and still writes its summary), writes
# loadgen-memory-abort and exits 98: the result is invalid, not a failure of the
# system under test. The lowest MemAvailable seen goes to loadgen-mem-min-pct.
. /opt/perf/scripts/lib.sh

SCRIPT=${1:?usage: run-k6.sh <script.js>}
shift || true
NAME=$(basename "$SCRIPT" .js)
RAMP=${RAMP:-2m}
HOLD=${HOLD:-10m}
export RAMP HOLD

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-k6-$NAME"
mkdir -p "$OUT"
make_csr "$OUT"

cat > "$OUT/params.json" <<P
{"tool":"k6","script":"$(basename "$SCRIPT")","run_id":"$RUN_ID","node":"$PERF_NODE","rate":"${RATE:-50}","ramp":"$RAMP","hold":"$HOLD","count":"${COUNT:-}","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P

# Client-side metrics -> Prometheus (remote write), if the receiver is up.
OUT_ARGS=()
if curl -s -o /dev/null --max-time 5 "${PROM_RW_URL%/api/v1/write}/-/ready"; then
  OUT_ARGS=(-o experimental-prometheus-rw)
  export K6_PROMETHEUS_RW_SERVER_URL="$PROM_RW_URL"
  export K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),avg,max"
  export K6_PROMETHEUS_RW_PUSH_INTERVAL=5s
  export K6_PROMETHEUS_RW_STALE_MARKERS=true
fi

MEM_GUARD_PCT=${MEM_GUARD_PCT:-10}
mem_pct() { awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {printf "%d", a * 100 / t}' /proc/meminfo; }
mem_guard() { # mem_guard <k6 pid>
  local pid=$1 min=100 pct
  while kill -0 "$pid" 2>/dev/null; do
    pct=$(mem_pct)
    if [ "$pct" -lt "$min" ]; then min=$pct; echo "$min" > "$OUT/loadgen-mem-min-pct"; fi
    if [ "$pct" -lt "$MEM_GUARD_PCT" ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) load generator MemAvailable ${pct}% < ${MEM_GUARD_PCT}%: stopping k6 (result invalid)" |
        tee "$OUT/loadgen-memory-abort" >&2
      kill -TERM "$pid" 2>/dev/null
      return
    fi
    sleep 5
  done
}
rm -f "$OUT/loadgen-memory-abort" "$OUT/loadgen-mem-min-pct"

T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "k6 $NAME start (run $RUN_ID, $PERF_NODE, RATE=${RATE:-50})" "perf,k6,$NAME,$RUN_ID" "$T1")

set +e
k6 run \
  -e RUN_ID="$RUN_ID" -e PERF_NODE="$PERF_NODE" \
  -e CSR_FILE="$OUT/leaf.csr" -e SUMMARY_FILE="$OUT/summary.json" \
  --tag run_id="$RUN_ID" --tag node="$PERF_NODE" \
  "${OUT_ARGS[@]}" "$@" "$SCRIPT" > >(tee "$OUT/k6.log") 2>&1 &
k6_pid=$!
mem_guard "$k6_pid" &
guard_pid=$!
wait "$k6_pid"
rc=$?
kill "$guard_pid" 2>/dev/null
wait "$guard_pid" 2>/dev/null
set -e
if [ -f "$OUT/loadgen-memory-abort" ]; then rc=98; fi
echo "load generator lowest MemAvailable during k6: $(cat "$OUT/loadgen-mem-min-pct" 2>/dev/null || echo "?")%"
T3=$(now_ms)
annotate_end "$AID" "$T3"

# Steady state starts after the ramp (arrival-rate scripts only).
if [ "$NAME" = "consul-register-burst" ]; then T2=$T1; else T2=$((T1 + $(to_secs "$RAMP") * 1000)); fi
[ "$T2" -gt "$T3" ] && T2=$T3
[ "$T2" -gt "$T1" ] && annotate "k6 $NAME steady state" "perf,steady,$RUN_ID" "$T2" >/dev/null

idle cooldown "$COOLDOWN"
T4=$(now_ms)

add_phase baseline "$T0" "$T1"
add_phase warmup "$T1" "$T2"
add_phase steady "$T2" "$T3"
add_phase cooldown "$T3" "$T4"
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "k6 $NAME ($RUN_ID)"

upload_results "$OUT"
exit "$rc"
