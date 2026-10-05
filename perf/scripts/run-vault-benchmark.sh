#!/bin/bash
# Usage: run-vault-benchmark.sh <test.hcl>
#   WORKERS=64 run-vault-benchmark.sh /opt/perf/vault-benchmark/pki-sign-consul-nostore.hcl
#
# Timeline (same shape as the k6 steady-state tests):
#   BASELINE (5m idle) -> WARMUP (2m run, results discarded) -> DURATION (10m
#   measured) -> COOLDOWN (5m idle), then a Grafana export of the whole window.
# WARMUP=0 skips the warm-up. RPS=0 means unthrottled (as fast as WORKERS allow).
. /opt/perf/scripts/lib.sh

TEST=${1:?usage: run-vault-benchmark.sh <test.hcl>}
NAME=$(basename "$TEST" .hcl)
WARMUP=${WARMUP:-2m}
DURATION=${DURATION:-10m}
WORKERS=${WORKERS:-64}
RPS=${RPS:-0}

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-vb-$NAME"
mkdir -p "$OUT"
make_csr "$OUT"

# write_config <duration> <file>
write_config() {
  umask 077
  {
    cat <<CFG
vault_addr  = "$VAULT_ADDR"
vault_token = "$VAULT_TOKEN"
ca_pem_file = "$VAULT_CACERT"
duration    = "$1"
workers     = $WORKERS
report_mode = "json"
cleanup     = true
CFG
    if [ "$RPS" -gt 0 ]; then echo "rps = $RPS"; fi
    sed "s#__CSR_FILE__#$OUT/leaf.csr#g" "$TEST"
  } > "$2"
}

cat > "$OUT/params.json" <<P
{"tool":"vault-benchmark","test":"$(basename "$TEST")","run_id":"$RUN_ID","node":"$PERF_NODE","warmup":"$WARMUP","duration":"$DURATION","workers":$WORKERS,"rps":$RPS,"baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P

T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "vault-benchmark $NAME start (run $RUN_ID, $PERF_NODE, workers=$WORKERS)" "perf,vault-benchmark,$NAME,$RUN_ID" "$T1")

if [ "$WARMUP" != "0" ]; then
  echo "$(date -u +%H:%M:%S) warm-up: $WARMUP (results discarded)"
  write_config "$WARMUP" "$OUT/config.hcl"
  vault-benchmark run -config="$OUT/config.hcl" > /dev/null 2> "$OUT/warmup.log"
fi

T2=$(now_ms)
[ "$T2" -gt "$T1" ] && annotate "vault-benchmark $NAME steady state" "perf,steady,$RUN_ID" "$T2" >/dev/null
echo "$(date -u +%H:%M:%S) measured run: $DURATION"
write_config "$DURATION" "$OUT/config.hcl"
vault-benchmark run -config="$OUT/config.hcl" > "$OUT/result.json" 2> >(tee "$OUT/vault-benchmark.log" >&2)
T3=$(now_ms)
annotate_end "$AID" "$T3"
jq . "$OUT/result.json" || cat "$OUT/result.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)

add_phase baseline "$T0" "$T1"
add_phase warmup "$T1" "$T2"
add_phase steady "$T2" "$T3"
add_phase cooldown "$T3" "$T4"
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "vault-benchmark $NAME ($RUN_ID)"

upload_results "$OUT"
