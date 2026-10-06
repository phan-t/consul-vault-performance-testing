#!/bin/bash
# Stepped stress test: rerun a k6 script at a rising RATE until a pass criterion
# fails, to find sustained capacity, the knee and the limiting component.
# Usage: stress-k6.sh <script.js>
#   stress-k6.sh /opt/perf/k6/consul-leaf.js                    # from the 350/s target
#   START=350 FACTOR=2 MAX=12800 stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
# For the scripts built on arrivalScenario (consul-leaf.js,
# vault-sign-consul-mount.js). RATE is per load generator.
#
# Each step is a normal run-k6.sh run with RUN_ID=<RUN_ID>-r<rate>, so its
# results upload as usual. A step fails when:
#   * the script's k6 thresholds fail (k6 exit code 99), or
#   * k6 delivered less than MIN_ACHIEVED (default 0.95) of the iterations it
#     should have started. In an open model, dropped iterations mean every VU
#     was busy waiting: the system can't keep up. If the load generator's own
#     CPU is the busiest host, raise MAX_VUS or add a load generator instead.
#   * a Vault or Consul server's mean CPU over the hold exceeds SERVER_CPU_MAX
#     (default 90%; 0 turns it off): saturated, even if latency still holds.
#     The mean, not the peak, so one busy 10 s sample doesn't fail a step.
#   * a guardrail breaks during the hold: a Consul or Vault leader election, or
#     Autopilot failure tolerance below 2 for Consul or STEP_VAULT_MIN_FT
#     (default 2) for Vault. plan-2's T5 at 6400/s dropped Consul's failure
#     tolerance to 0 and that was only flagged.
# p99 and errors come from the steady scenario only (k6 lib/common.js), and k6
# aborts a step once more than 1 - MIN_ACHIEVED of its steady iterations were
# dropped; such a step is marked vu_starved: every VU was busy, so its latency
# is the load generator's queue, not the system's. Its numbers stay in
# stress.json but not in latency tables.
# The rate is multiplied by FACTOR (default 2) after each passing step, up to MAX
# (default 12800, which is always tried once before stopping). Once the busiest
# server's mean CPU reaches FINE_CPU (default 50%), it switches to FINE_FACTOR
# (default 1.5): doubling is too coarse near the ceiling. Steps below FINE_CPU
# hold LOW_HOLD (default 5m: plan-1 showed steady state within 1-4 minutes),
# steps after it HOLD (10m). RATES="200 400 800 ..." runs that fixed list
# instead, every step holding HOLD (T11: the same grid at every voter count),
# still stopping at the first failure. Each step's warm-up starts at the
# previous step's rate, so load doesn't dip between steps.
#
# Steps are chained: one BASELINE (5m idle) before the first step, then each
# step back to back with its own RAMP warm-up and HOLD steady state (2m + 10m by
# default), then one COOLDOWN (5m idle) and one Grafana export of the whole run
# with every step's warm-up and steady window as its own phase
# (warmup-r<rate>, steady-r<rate>). STEP_GAP (default 0) adds a pause between
# steps.
#
# For the mesh path (consul-leaf.js), remove Consul's CSR limits first
# (consul-ca-limits.sh 0 0), otherwise the ceiling found is the limiter's. The
# client agent caches every leaf, so it is restarted before the first step and
# between steps (RESTART_AGENT, default true for consul-leaf.js).
#
# If run-k6.sh's load generator memory guard stops a step (exit 98), the step is
# recorded as invalid (not a failure) and the stress stops: rates from there on
# measure the load generator, not the system under test. Every step records the
# load generator's lowest MemAvailable (loadgen_min_mem_pct).
#
# Writes <RUN_ID>-<node>-stress-<script>/stress.json: per step the target rate,
# threshold result, delivered fraction, failure rate, p50/p95/p99 (ms), the
# busiest hosts' peak CPU over the hold, and sign requests per Vault node on
# Consul's intermediate (does Consul's signing spread at high rates?), Vault
# Raft commit time and applies/s (vault_raft), server-side latency (Vault's sign
# route and every Vault request: with the client's p99, where the time goes;
# Consul 2.0.1 has no sign-latency metric of its own), Raft storage (log append with fsync, BoltDB writes, disk
# write latency, /opt/vault/data size and growth); then the last passing rate,
# why it stopped, and the knee (the first step where p95 grew faster than the rate).
. /opt/perf/scripts/lib.sh

SCRIPT=${1:?usage: stress-k6.sh <script.js>}
shift || true

NAME_FOR_START=$(basename "$SCRIPT" .js)
# Default start rate: the 350/s target (README "Targets") on the signing and
# leaf paths; 50/s otherwise.
case "$NAME_FOR_START" in
vault-sign-consul-mount | consul-leaf) START=${START:-350} ;;
*) START=${START:-50} ;;
esac
FACTOR=${FACTOR:-2}
FINE_CPU=${FINE_CPU:-50}
FINE_FACTOR=${FINE_FACTOR:-1.5}
MAX=${MAX:-12800}
MIN_ACHIEVED=${MIN_ACHIEVED:-0.95}
SERVER_CPU_MAX=${SERVER_CPU_MAX:-90}
STEP_GAP=${STEP_GAP:-0}
HOLD=${HOLD:-10m}
LOW_HOLD=${LOW_HOLD:-5m}
export HOLD
NAME=$(basename "$SCRIPT" .js)
# A fixed RATES list replaces START/MAX (read before the run is annotated).
if [ -n "${RATES:-}" ]; then
  read -r -a rate_list <<<"$RATES"
  START=${rate_list[0]}
  MAX=${rate_list[-1]}
fi
next_rate() { # next_rate <rate>: the next step's rate (beyond MAX when done)
  if [ -n "${RATES:-}" ]; then
    local r
    for r in "${rate_list[@]}"; do [ "$r" -gt "$1" ] && { echo "$r"; return; }; done
    echo $((MAX + 1))
  else
    # x FACTOR, or FINE_FACTOR once near the ceiling; MAX itself is tried once.
    local n
    n=$(awk -v r="$1" -v f="$step_factor" 'BEGIN { printf "%d", r * f }')
    if [ "$1" -lt "$MAX" ] && [ "$n" -gt "$MAX" ]; then n=$MAX; fi
    echo "$n"
  fi
}
step_factor=$FACTOR
if [ -n "${RATES:-}" ]; then step_hold=$HOLD; else step_hold=$LOW_HOLD; fi
prev_rate=

if [ -z "${RESTART_AGENT:-}" ]; then
  if [ "$NAME" = consul-leaf ]; then RESTART_AGENT=true; else RESTART_AGENT=false; fi
fi

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-stress-$NAME"
mkdir -p "$OUT"
echo '[]' > "$OUT/steps.json"
PROM=$(prom_url || true)

CPU_EXPR='100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))'
STEP_PHASES="[]"

[ "$RESTART_AGENT" = true ] && restart_consul_agent

T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
if [ -n "${RATES:-}" ]; then steps_desc="RATES=$RATES"; else steps_desc="START=$START x$FACTOR"; fi
AID=$(annotate "stress $NAME start (run $RUN_ID, $PERF_NODE, $steps_desc)" "perf,stress,$NAME,$RUN_ID" "$T1")

rate=$START
stop_reason="reached MAX ($MAX)"
while [ "$rate" -le "$MAX" ]; do
  step="$RUN_ID-r$rate"
  echo "=== stress step: RATE=$rate (RUN_ID=$step)"
  set +e
  # Chained: the step has no idle windows or export of its own.
  env RUN_ID="$step" RATE="$rate" HOLD="$step_hold" ${prev_rate:+START_RATE=$prev_rate} BASELINE=0 COOLDOWN=0 EXPORT=0 \
    run-k6.sh "$SCRIPT" --summary-trend-stats "avg,min,med,max,p(90),p(95),p(99)" "$@"
  rc=$?
  set -e
  STEP_DIR="$RESULTS_DIR/$step-$PERF_NODE-k6-$NAME"
  STEP_PHASES=$(jq -c --arg r "$rate" --argjson acc "$STEP_PHASES" \
    '$acc + [.[] | select(.name == "warmup" or .name == "steady") | .name += "-r" + $r]' "$STEP_DIR/phases.json" 2>/dev/null || echo "$STEP_PHASES")

  case $rc in
  0) thr=pass ;;
  99) thr=fail ;;
  98) thr=invalid ;;
  *) stop_reason="k6 exited $rc, not a threshold failure; see the step's k6.log"; break ;;
  esac

  memmin=$(cat "$STEP_DIR/loadgen-mem-min-pct" 2>/dev/null || echo null)
  step_json=$(jq -c --argjson rate "$rate" --arg thr "$thr" --argjson memmin "$memmin" --arg hold "$step_hold" '
    .metrics as $m
    | ([$m | to_entries[] | select(.key | startswith("http_req_duration{name:"))][0].value.values) as $d
    | ([$m | to_entries[] | select(.key | startswith("http_req_failed{name:"))][0].value.values.rate) as $f
    | ($m.iterations.values.count // 0) as $it
    | ($m.dropped_iterations.values.count // 0) as $dr
    | {rate: $rate, hold: $hold, thresholds: $thr, invalid: ($thr == "invalid"), loadgen_min_mem_pct: $memmin, failed_rate: $f,
       p50_ms: $d.med, p95_ms: $d["p(95)"], p99_ms: $d["p(99)"],
       iterations: $it, dropped: $dr,
       delivered: (if ($it + $dr) > 0 then $it / ($it + $dr) else 0 end)}' \
    "$STEP_DIR/summary.json")

  [ -n "$PROM" ] && sleep 20 # let Prometheus scrape the step's last seconds
  cpu='null'
  scpu='null'
  guard='null'
  slat='null'
  vst='null'
  raft='null'
  lcost='null'
  # Measure the step's steady state (from its phases.json), not the cooldown.
  if [ -n "$PROM" ] && read -r s_start t_end < <(steady_window "$STEP_DIR"); then
    hold_s=$((t_end - s_start))
    cpu=$(prom_query "$PROM" "topk(4, max_over_time(($CPU_EXPR)[${hold_s}s:10s]))" "$t_end" |
      jq -c 'map({instance: .metric.instance, cpu_pct: (.value[1] | tonumber | . * 10 | round / 10)})' || true)
    cpu=${cpu:-null}
    scpu=$(server_cpu "$PROM" "$s_start" "$t_end")
    slat=$(server_latency "$PROM" "$s_start" "$t_end" || echo null)
    vst=$(vault_storage "$PROM" "$s_start" "$t_end" || echo null)
    guard=$(guardrails $((s_start * 1000)) $((t_end * 1000)) "${STEP_VAULT_MIN_FT:-2}" | jq -c 'del(.scanner_hosts)' 2>/dev/null || echo null)
    signs=$(prom_query "$PROM" "sum by (instance) (increase(${SIGN_METRIC}[${hold_s}s]))" "$t_end" |
      jq -c 'map({instance: .metric.instance, signs: (.value[1] | tonumber)})
        | (map(.signs) | add // 0) as $t
        | if $t == 0 then null else
            (max_by(.signs)) as $b
            | {busiest: $b.instance, busiest_share: ($b.signs / $t * 1000 | round / 1000),
               nodes_serving: (map(select(.signs / $t >= 0.01)) | length)} end' || true)
    signs=${signs:-null}
    vconns=$(prom_query "$PROM" "max(max_over_time(perf_vault_connections{role=\"consul\"}[${hold_s}s]))" "$t_end" |
      jq -c '.[0].value[1] // null | if . then tonumber else null end' || true)
    signs=$(jq -c --argjson c "${vconns:-null}" 'if . then . + {consul_vault_connections_max: $c} else {consul_vault_connections_max: $c} end' <<<"$signs")
    raft=$(vault_raft_stats "$PROM" "$s_start" "$t_end" || echo null)
    lcost=$(vault_leader_cost "$PROM" "$s_start" "$t_end" || echo null)
  else
    signs='null'
  fi
  # Leader cost per write: the steady-state write rate is the offered rate times the delivered fraction.
  step_json=$(jq -c --argjson cpu "$cpu" --argjson scpu "${scpu:-null}" --argjson cmax "$SERVER_CPU_MAX" --argjson guard "${guard:-null}" \
    --argjson slat "${slat:-null}" --argjson vst "${vst:-null}" \
    --argjson signs "$signs" --argjson raft "${raft:-null}" --argjson lc "${lcost:-null}" \
    --argjson min "$MIN_ACHIEVED" '(.rate * .delivered) as $w
    | ($cmax > 0 and ($scpu.cpu_pct // 0) > $cmax) as $sat
    | . + {peak_cpu: $cpu, server_cpu_mean: $scpu, cpu_saturated: $sat, guardrails: $guard,
           server_latency: $slat, vault_storage: $vst,
           vu_starved: (.delivered < $min and .dropped > 0), sign_nodes: $signs, vault_raft: $raft,
           leader_cost: (if $lc and $w > 0 then $lc + {
             tx_bytes_per_write: (if $lc.tx_bytes_per_s then ($lc.tx_bytes_per_s / $w | round) else null end),
             cpu_ms_per_write: (if $lc.cpu_cores then ($lc.cpu_cores / $w * 1000 * 1000 | round / 1000) else null end)} else $lc end),
           pass: (.thresholds == "pass" and .delivered >= $min and ($sat | not) and ($guard.ok // true))}' <<<"$step_json")
  jq --argjson s "$step_json" '. + [$s]' "$OUT/steps.json" > "$OUT/steps.tmp" && mv "$OUT/steps.tmp" "$OUT/steps.json"
  echo "step: $step_json"

  if [ "$thr" = invalid ]; then
    stop_reason="step at RATE=$rate invalid: the load generator ran out of memory (MemAvailable < ${MEM_GUARD_PCT:-10}%); higher rates need more load generator memory"
    break
  fi
  if [ "$(jq -r .pass <<<"$step_json")" != true ]; then
    stop_reason="step at RATE=$rate failed: thresholds $thr, delivered $(jq -r '.delivered * 1000 | round / 1000' <<<"$step_json"), server CPU $(jq -r '.server_cpu_mean | if . then "\(.instance) \(.cpu_pct)%" else "?" end' <<<"$step_json")$(jq -r 'if .cpu_saturated then " (over '"$SERVER_CPU_MAX"'%)" else "" end' <<<"$step_json")$(jq -r 'if .vu_starved then ", VU-starved" else "" end' <<<"$step_json")$(jq -r 'if (.guardrails.ok // true) | not then ", guardrails \(.guardrails | del(.ok) | tojson)" else "" end' <<<"$step_json")"
    break
  fi
  # Near the ceiling: finer steps, full holds.
  if [ -z "${RATES:-}" ] && [ "$(jq -r '(.server_cpu_mean.cpu_pct // 0) >= '"$FINE_CPU" <<<"$step_json")" = true ]; then
    step_factor=$FINE_FACTOR
    step_hold=$HOLD
  fi
  prev_rate=$rate
  rate=$(next_rate "$rate")
  if [ "$rate" -le "$MAX" ]; then
    [ "$RESTART_AGENT" = true ] && restart_consul_agent
    sleep "$(dur_s "$STEP_GAP")"
  fi
done

T3=$(now_ms)
annotate_end "$AID" "$T3"
idle cooldown "$COOLDOWN"
T4=$(now_ms)

jq --arg script "$(basename "$SCRIPT")" --arg run "$RUN_ID" --arg node "$PERF_NODE" \
  --argjson start "$START" --argjson factor "$FACTOR" --argjson max "$MAX" \
  --argjson min "$MIN_ACHIEVED" --arg hold "$HOLD" --arg reason "$stop_reason" '
  . as $s
  | [$s[] | select(.invalid | not)] as $v
  | {script: $script, run_id: $run, node: $node, start: $start, factor: $factor, max: $max,
     min_achieved: $min, hold: $hold, steps: $s,
     last_pass_rate: ([$s[] | select(.pass) | .rate] | max),
     stop_reason: $reason,
     invalid_rate: ([$s[] | select(.invalid) | .rate] | first),
     knee_between: ([range(1; $v | length)
       | select($v[.].p95_ms != null and $v[. - 1].p95_ms != null and $v[. - 1].p95_ms > 0)
       | select(($v[.].p95_ms / $v[. - 1].p95_ms) > ($v[.].rate / $v[. - 1].rate))
       | [$v[. - 1].rate, $v[.].rate]][0])}' \
  "$OUT/steps.json" > "$OUT/stress.json"
rm -f "$OUT/steps.json"

echo
jq -r '"rate\tthresholds\tdelivered\tfailed\tp95_ms\tp99_ms\tvault commit mean/p99 ms\tleader B/write\tloadgen min mem\tbusiest host\tsigning nodes",
  (.steps[] | [.rate, .thresholds, (.delivered * 1000 | round / 1000), .failed_rate,
    (.p95_ms // 0 | round), (.p99_ms // 0 | round),
    (.vault_raft | if . then "\(.commit_mean_ms // "-") / \(.commit_p99_ms // "-")" else "-" end),
    (.leader_cost.tx_bytes_per_write // "-"),
    "\(.loadgen_min_mem_pct // "?")%",
    ((.peak_cpu // [])[0] | if . then "\(.instance) \(.cpu_pct)%" else "-" end),
    (.sign_nodes | if . then "\(.nodes_serving) (top \(.busiest) \(.busiest_share))" else "-" end)] | @tsv),
  "", "last passing rate: \(.last_pass_rate)", "stopped: \(.stop_reason)",
  "knee between: \(.knee_between // "not reached")"' "$OUT/stress.json"
PHASES=$(jq -c -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson t3 "$T3" --argjson t4 "$T4" --argjson steps "$STEP_PHASES" \
  '[{name: "baseline", start: $t0, end: $t1}] + $steps + [{name: "cooldown", start: $t3, end: $t4}]
   | map(select(.end > .start))')
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "stress $NAME ($RUN_ID)"
upload_results "$OUT"
