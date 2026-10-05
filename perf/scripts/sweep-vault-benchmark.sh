#!/bin/bash
# Worker sweep for vault-benchmark (T1): one run per WORKERS level, chained.
#   WORKERS_LIST="16 64 128" RUN_ID=t1 sweep-vault-benchmark.sh /opt/perf/vault-benchmark/pki-sign-consul-nostore.hcl
#
# Timeline: one BASELINE (5m idle) -> each level back to back, each with its own
# WARMUP (2m, discarded) and DURATION (10m measured) -> one COOLDOWN (5m idle)
# -> one Grafana export with each level's warm-up and steady window as its own
# phase (warmup-w<N>, steady-w<N>).
# Each level is a normal run-vault-benchmark.sh run with RUN_ID=<RUN_ID>-w<N>;
# summarise.sh <RUN_ID> picks up every level plus this sweep's export.
. /opt/perf/scripts/lib.sh

TEST=${1:?usage: sweep-vault-benchmark.sh <test.hcl>}
NAME=$(basename "$TEST" .hcl)
WORKERS_LIST=${WORKERS_LIST:-"16 64 128"}

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-sweep-$NAME"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"vault-benchmark-sweep","test":"$(basename "$TEST")","run_id":"$RUN_ID","node":"$PERF_NODE","workers":"$WORKERS_LIST","warmup":"${WARMUP:-2m}","duration":"${DURATION:-10m}","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P

STEP_PHASES="[]"
T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "vault-benchmark sweep $NAME (run $RUN_ID, workers $WORKERS_LIST)" "perf,sweep,$NAME,$RUN_ID" "$T1")

for w in $WORKERS_LIST; do
  step="$RUN_ID-w$w"
  echo "=== sweep level: WORKERS=$w (RUN_ID=$step)"
  RUN_ID="$step" WORKERS="$w" BASELINE=0 COOLDOWN=0 EXPORT=0 run-vault-benchmark.sh "$TEST" > "$OUT/w$w.log" 2>&1 ||
    echo "level WORKERS=$w failed; see $OUT/w$w.log"
  d="$RESULTS_DIR/$step-$PERF_NODE-vb-$NAME"
  STEP_PHASES=$(jq -c --arg w "$w" --argjson acc "$STEP_PHASES" \
    '$acc + [.[] | select(.name == "warmup" or .name == "steady") | .name += "-w" + $w]' "$d/phases.json" 2>/dev/null || echo "$STEP_PHASES")
  jq -c --argjson w "$w" '(.metrics.total // (.metrics | to_entries[0].value)) as $t
    | {workers: $w, requests: $t.requests, rps: ($t.throughput | . * 10 | round / 10), success: $t.success,
       p50_ms: ($t.latencies["50th"] / 1e6 | . * 100 | round / 100), p95_ms: ($t.latencies["95th"] / 1e6 | . * 100 | round / 100),
       p99_ms: ($t.latencies["99th"] / 1e6 | . * 100 | round / 100)}' "$d/result.json" 2>/dev/null | tee -a "$OUT/levels.jsonl" || true
done

T3=$(now_ms)
annotate_end "$AID" "$T3"
idle cooldown "$COOLDOWN"
T4=$(now_ms)

jq -s '.' "$OUT/levels.jsonl" > "$OUT/sweep.json" 2>/dev/null && rm -f "$OUT/levels.jsonl"
echo
jq -r '"workers\trps\tp50_ms\tp95_ms\tp99_ms\tsuccess", (.[] | [.workers, .rps, .p50_ms, .p95_ms, .p99_ms, .success] | @tsv)' \
  "$OUT/sweep.json" | column -t -s $'\t'

PHASES=$(jq -c -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson t3 "$T3" --argjson t4 "$T4" --argjson steps "$STEP_PHASES" \
  '[{name: "baseline", start: $t0, end: $t1}] + $steps + [{name: "cooldown", start: $t3, end: $t4}]
   | map(select(.end > .start))')
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "vault-benchmark sweep $NAME ($RUN_ID)"
upload_results "$OUT"
