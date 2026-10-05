#!/bin/bash
# Consul signing distribution: does the Consul leader's signing reach one Vault
# node at a time, while direct clients spread across every node?
# Usage: RATE=100 signing-distribution.sh
#
# Expected from the source: only the Consul leader calls Vault; its Vault API
# client carries concurrent requests over one pooled HTTP/2 connection; the NLB
# picks a target per TCP connection. So Consul-driven signing should sit on one
# Vault node until that connection closes (90 s idle in the Go transport).
#
# Runs, each a full run-k6.sh run (BASELINE, RAMP, HOLD, COOLDOWN, export):
#   1. control   vault-sign-consul-mount.js at RATE (direct clients)
#   2. mesh-1    consul-leaf.js at RATE (agent -> Consul leader -> Vault)
#   3. no load for IDLE (default 150s) so the leader's idle connection closes
#      (mesh-1's cooldown and mesh-2's baseline already add 2 x 5m idle)
#   4. mesh-2    consul-leaf.js at RATE again
# Consul's CSR limits are removed for the test and restored afterwards.
#
# After each run, Prometheus gives sign requests per Vault node on Consul's
# intermediate over the hold, overall and per minute. Verdict per run:
#   spread        every Vault node took at least 1% of sign requests
#   concentrated  the busiest node took at least SHARE (default 0.9) in every minute
#   mixed         neither
# The expected behaviour is confirmed if the control is spread and both mesh
# runs are concentrated. Then compare capacity with and without non-voters
# using stress-k6.sh (see README).
#
# Writes <RUN_ID>-<node>-signing-distribution/distribution.json.
. /opt/perf/scripts/lib.sh

RATE=${RATE:-100}
SHARE=${SHARE:-0.9}
IDLE=${IDLE:-150s}
HOLD=${HOLD:-10m}
export RATE HOLD
HOLD_S=$(dur_s "$HOLD")
PROM=$(prom_url)

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-signing-distribution"
mkdir -p "$OUT"
echo '[]' > "$OUT/runs.json"

SIGN=$SIGN_METRIC

# Remove Consul's CSR limits, restoring the current ones on exit.
limits=$(consul-ca-limits.sh)
old_rate=$(jq -r '.Config.CSRMaxPerSecond // .Config.csr_max_per_second // 50' <<<"$limits")
old_conc=$(jq -r '.Config.CSRMaxConcurrent // .Config.csr_max_concurrent // 0' <<<"$limits")
trap 'echo "restoring Consul CSR limits: $old_rate/s, $old_conc concurrent"; consul-ca-limits.sh "$old_rate" "$old_conc"' EXIT
consul-ca-limits.sh 0 0

nodes=$(prom_query "$PROM" 'up{job="vault"} == 1' "$(date +%s)" |
  jq -c 'map({instance: .metric.instance, voter: .metric.voter}) | sort_by(.instance)')
node_count=$(jq length <<<"$nodes")
echo "Vault nodes up: $(jq -r 'map("\(.instance) (voter=\(.voter))") | join(", ")' <<<"$nodes")"

run_and_measure() {
  local label=$1 script=$2 step=$RUN_ID-$1 rc t_end t_start overall minutes
  echo "=== $label: RATE=$RATE $(basename "$script")"
  set +e
  RUN_ID="$step" run-k6.sh "$script"
  rc=$?
  set -e
  # The run's steady state from its phases.json: run-k6.sh returns only after
  # its cooldown and Grafana export, so "now minus HOLD" would miss the hold.
  read -r t_start t_end < <(steady_window "$RESULTS_DIR/$step-$PERF_NODE-k6-$(basename "$script" .js)")
  HOLD_S=$((t_end - t_start))

  overall=$(prom_query "$PROM" "sum by (instance) (increase(${SIGN}[${HOLD_S}s]))" "$t_end")
  # Per-minute buckets need a hold of at least 1 minute; clamp so shorter
  # holds (quick checks) still give one bucket instead of an invalid range.
  local m_start=$((t_start + 60))
  [ "$m_start" -gt "$t_end" ] && m_start=$t_end
  minutes=$(prom_range "$PROM" "sum by (instance) (increase(${SIGN}[1m]))" \
    "$m_start" "$t_end" 60)

  jq -n -c --arg label "$label" --arg script "$(basename "$script")" --arg run "$step" \
    --argjson rc "$rc" --argjson t0 "$t_start" --argjson t1 "$t_end" \
    --argjson overall "$overall" --argjson minutes "$minutes" \
    --argjson n "$node_count" --argjson share "$SHARE" '
    ($overall | map({instance: .metric.instance, signs: (.value[1] | tonumber)})) as $o
    | ([$o[].signs] | add // 0) as $total
    | ($o | map(. + {share: (if $total > 0 then .signs / $total else 0 end)})
          | sort_by(-.share)) as $per_node
    | ([$minutes[] | .metric.instance as $i | .values[]
          | {t: .[0], instance: $i, v: (.[1] | tonumber)}]
       | group_by(.t)
       | map((map(.v) | add) as $sum | max_by(.v)
             | {t: .t, busiest: .instance,
                share: (if $sum > 0 then .v / $sum else 0 end)})
       | map(select(.share > 0))) as $per_min
    | ([$per_node[] | select(.share >= 0.01)] | length) as $serving
    | {label: $label, script: $script, run_id: $run, k6_exit: $rc,
       hold_start: ($t0 | todate), hold_end: ($t1 | todate),
       sign_requests: ($total | round), nodes_serving: $serving,
       per_node: ($per_node | map(.signs |= round | .share |= (. * 1000 | round / 1000))),
       per_minute: ($per_min | map(.t |= todate | .share |= (. * 1000 | round / 1000))),
       busiest_nodes: ([$per_min[].busiest] | unique),
       first_busiest: ($per_min | first | .busiest?),
       last_busiest: ($per_min | last | .busiest?),
       min_busiest_share: ([$per_min[].share] | min | if . then . * 1000 | round / 1000 else . end),
       verdict: (if $total == 0 then "no data"
                 elif $serving >= $n then "spread"
                 elif ([$per_min[].share] | min) >= $share then "concentrated"
                 else "mixed" end)}' > "$OUT/run.json"
  jq --slurpfile r "$OUT/run.json" '. + $r' "$OUT/runs.json" > "$OUT/runs.tmp" && mv "$OUT/runs.tmp" "$OUT/runs.json"
  rm -f "$OUT/run.json"
  jq -r '.[-1] | "\(.label): \(.verdict); \(.nodes_serving) node(s) serving; busiest per minute: \(.busiest_nodes | join(", ")); lowest busiest-node share \(.min_busiest_share)"' "$OUT/runs.json"
}

run_and_measure control /opt/perf/k6/vault-sign-consul-mount.js
run_and_measure mesh-1 /opt/perf/k6/consul-leaf.js
echo "=== idle for $IDLE"
sleep "$(dur_s "$IDLE")"
run_and_measure mesh-2 /opt/perf/k6/consul-leaf.js

jq --arg run "$RUN_ID" --argjson rate "$RATE" --argjson share "$SHARE" --arg idle "$IDLE" \
  --arg hold "$HOLD" --argjson nodes "$nodes" '
  . as $r
  | ($r | map({(.label): .}) | add) as $by
  | {run_id: $run, rate: $rate, hold: $hold, idle: $idle, share_threshold: $share,
     vault_nodes: $nodes, runs: $r,
     expected_behaviour: (if $by.control.verdict == "spread"
                            and $by["mesh-1"].verdict == "concentrated"
                            and $by["mesh-2"].verdict == "concentrated"
                          then "confirmed"
                          elif $by["mesh-1"].verdict == "spread" or $by["mesh-2"].verdict == "spread"
                          then "refuted"
                          else "inconclusive" end),
     busiest_node_changed_after_idle:
       ($by["mesh-1"].last_busiest != $by["mesh-2"].first_busiest)}' \
  "$OUT/runs.json" > "$OUT/distribution.json"
rm -f "$OUT/runs.json"

echo
jq -r '"expected behaviour: \(.expected_behaviour)",
  "busiest node changed after idle: \(.busiest_node_changed_after_idle)"' "$OUT/distribution.json"
upload_results "$OUT"
