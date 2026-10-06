#!/bin/bash
# Run the TEST-PLAN.md test sequence unattended on a load generator.
#
#   run-plan.sh start [PLAN]    launch detached (systemd unit perf-plan-<PLAN>):
#                               settle -> T1 -> T2 -> T3 -> T3c -> T5 -> T6 -> T3r
#                               -> T5r -> T9-V -> Stage 4: t11grow -> t11smoke
#                               -> t11v7 -> t11v5 -> t11v3
#   run-plan.sh status [PLAN]   progress, key numbers, RESULTS.md
#   run-plan.sh stop [PLAN]     stop (Consul CSR limits are restored)
#   run-plan.sh t9v [PLAN]      run (or re-run) only T9-V
#
# Fully unattended when Stage 0 provisions the Vault non-voters held
# (vault_non_voter_count = 2, vault_non_voters_start = false): T9-V starts them
# over SSM, waits for them to join as non-voters, then reruns T3 (from T3's last
# passing rate) and T3c. No terraform apply is needed after Stage 0. Without
# held non-voters, T9-V is skipped (or run `t9v` after applying them).
#
# settle runs any due apt jobs on every node now (apt-daily, unattended-upgrades)
# and waits for dpkg locks to clear, idles SETTLE_IDLE (10m), then checks the
# last 5 minutes were quiet in Prometheus (busiest non-monitoring host CPU <
# SETTLE_MAX_CPU %, default 15, and no leader elections), retrying up to 3 times
# before continuing with a recorded warning. SETTLE_APT=0 skips the apt jobs.
# Before those checks it waits up to SETTLE_SCANNER_WAIT (60m) for security
# scanners (perf_scanner_active, e.g. a vulnerability scanner on the image) to finish, and
# a quiet check also requires no scanner activity. Every test records which
# hosts ran a scanner during it; RESULTS.md flags those tests.
#
# Stage 4 runs T11 (Vault Raft commit latency vs voter count: t11v7 t11v5
# t11v3) last, on the same build: t11grow turns T9-V's two non-voters into
# voters (vault-raft-voters.sh convert: stop, remove-peer, wipe Raft data,
# retry_join_as_non_voter = false, start), giving 7 voters spread 3/2/2, and
# records each node's join and Autopilot promotion time. T11 also runs as its
# own campaign on a vault_voter_count = 7 build (below). Either way it needs
# no non-voters in Raft and a Vault license without the pki-only module (KV
# mounts). Each size shrinks Vault in place first
# (vault-raft-voters.sh: stop + remove-peer of 2 non-active voters, AZ spread
# kept), then one chained timeline (one baseline, one cooldown, like T3/T5): a
# KV v2 write stress over a fixed rate grid (vault-kv-write.js, T11_KV_RATES,
# T11_KV_REPEATS times) and a payload sweep (T11_PAYLOADS at T11_PAYLOAD_RATE),
# recording Vault Raft commit time per step, then a failover check (vault-failover-test.sh): T11_FAILOVER_REPEATS
# times, SIGSTOP the active node under 20 writes/s and time the new active node
# and the longest write gap. Its guardrails cover the resize to the failover
# (exclusive) and expect failure tolerance (N-1)/2. The shrink is one-way:
# rebuild to get the voters back.
# t11smoke (also opt-in) runs a ~15 min T11 at the current size first, without
# shrinking, and checks the measurements T11 depends on (Autopilot fields, Raft
# commit time, leader cost, failover timing). If it fails, t11v* refuse to run,
# so a broken measurement stops the campaign instead of costing 9-11 h.
#   PLAN_TESTS="settle t11smoke t11v7 t11v5 t11v3" run-plan.sh start raft-1
# (scripts/run-campaign.sh start raft-1 --t11 builds and starts exactly this.)
#
# PLAN_TESTS="settle t1 ..." runs only the listed tests (in plan order), e.g.
# everything but Stage 4: PLAN_TESTS="settle t1 t2 t3 t3c t5 t6 t3r t5r t9v".
#   run-plan.sh run [PLAN]      run in the foreground (what `start` launches)
#
# PLAN defaults to plan-<UTC date>. RUN_IDs are <PLAN>-t1, <PLAN>-t3, ...
# State: /opt/perf/results/<PLAN>-plan/{state.json,RESULTS.md,run.log}, also
# uploaded to s3://<bucket>/results/<PLAN>-plan/. Re-running resumes: completed
# tests are skipped. Decisions carried between tests:
#   T1 knee (last worker level that still added >= 10% throughput) -> T2 WORKERS
#   T3/T5 last pass / first fail -> refinement rate (midpoint) and T9-V START
# After every test the guardrails are checked over its window (Consul/Vault
# leader elections, minimum Autopilot failure tolerance) and flagged in
# RESULTS.md.
#
# Overrides (defaults = TEST-PLAN.md): T1_WORKERS, T1_CONNS, T1_STEP, T1_WARMUP,
# T3_START, T3_MAX, T5_START,
# T5_MAX, T3C_CONCURRENCY, T3C_MULTI_CONNS, T3C_STEP, T6_RATE, T6_BASELINE,
# T6_COOLDOWN, T6_RAMP, T6_HOLD, T6_IDLE, T11_KV_RATES, T11_KV_REPEATS, T11_PAYLOADS,
# T11_PAYLOAD_RATE, T11_RAMP, T11_HOLD, T11_KV_P99_MS,
#, T11_RESIZE_SETTLE, T11_FAILOVER_REPEATS, T11_FREEZE, plus the usual BASELINE, COOLDOWN, RAMP,
# HOLD, WARMUP, DURATION, EXPORT for every test.
. /opt/perf/scripts/lib.sh

CMD=${1:-status}
PLAN=${2:-${PLAN:-plan-$(date -u +%Y%m%d)}}
DIR="$RESULTS_DIR/$PLAN-plan"
STATE="$DIR/state.json"
UNIT="perf-plan-$PLAN"
mkdir -p "$DIR"
[ -s "$STATE" ] || echo '{"plan": "'"$PLAN"'", "tests": {}, "values": {}}' > "$STATE"

T1_WORKERS=${T1_WORKERS:-"32 64 128 256"}
T1_CONNS=${T1_CONNS:-32}
T1_STEP=${T1_STEP:-10m}
T1_WARMUP=${T1_WARMUP:-2m}
T3C_CONCURRENCY=${T3C_CONCURRENCY:-"1 8 32 64 128 256 512"}
T3C_MULTI_CONNS=${T3C_MULTI_CONNS:-16}
T3C_STEP=${T3C_STEP:-60s}
T6_RATE=${T6_RATE:-100}
SETTLE_APT=${SETTLE_APT:-1}
SETTLE_IDLE=${SETTLE_IDLE:-10m}
SETTLE_MAX_CPU=${SETTLE_MAX_CPU:-15}
SETTLE_SCANNER_WAIT=${SETTLE_SCANNER_WAIT:-60m}
# The same rate grid at every voter count: T3's rates (200/s doubling, to T3's
# 12800 max) plus midpoints near saturation, where the leader's fan-out to N-1
# followers shows. Stops at the first failing rate, so unreached rates cost nothing.
T11_KV_RATES=${T11_KV_RATES:-"200 400 800 1600 2400 3200 4800 6400 9600 12800"}
T11_KV_REPEATS=${T11_KV_REPEATS:-2}
# Value sizes for the payload sweep, at T11_PAYLOAD_RATE (on the grid, so 1 KiB is its reference).
T11_PAYLOADS=${T11_PAYLOADS:-"16384 65536"}
T11_PAYLOAD_RATE=${T11_PAYLOAD_RATE:-400}
# T11 steps keep the plan's 2m warm-up (it absorbs carry-over, e.g. from the
# failed last step of one KV run into the next run's 200/s) but hold 5m, not
# 10m: the repeats measure the noise instead. T11_HOLD=10m restores the
# convention (~15 h).
T11_RAMP=${T11_RAMP:-2m}
T11_HOLD=${T11_HOLD:-5m}
# KV writes have no target (T3's 100 ms is Vault's signing target, and KV v2 on
# 7 voters is already ~130 ms p99 at 200/s), so the grid stops at saturation:
# p99 > 1 s, errors >= 0.1% or < 95% delivered.
T11_KV_P99_MS=${T11_KV_P99_MS:-1000}
T11_RESIZE_SETTLE=${T11_RESIZE_SETTLE:-2m}
T11_FAILOVER_REPEATS=${T11_FAILOVER_REPEATS:-3}
# The freeze must outlast detection + election + takeover: 8-11 s to a new
# active node in the raft-1 run, so 60 s leaves ample room.
T11_FREEZE=${T11_FREEZE:-60s}
PLAN_TESTS=${PLAN_TESTS:-}

# --- state helpers ------------------------------------------------------------
sget() { jq -r "$1 // empty" "$STATE"; }
sset() { # sset <jq path> <json value>
  jq --argjson v "$2" "$1 = \$v" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$DIR/run.log"; }
upload_state() {
  aws s3 cp --recursive --only-show-errors "$DIR" "s3://$PERF_BUCKET/results/$PLAN-plan/" || true
}
done_test() { [ "$(sget ".tests[\"$1\"].status")" = done ]; }

# --- Consul CSR limits (T5 / T5r) ---------------------------------------------
limits_remove() {
  if [ -z "$(sget '.values.csr_saved')" ]; then
    local cfg
    cfg=$(consul-ca-limits.sh)
    sset '.values.csr_saved' "$(jq -c '{rate: (.Config.CSRMaxPerSecond // .Config.csr_max_per_second // 50),
      concurrent: (.Config.CSRMaxConcurrent // .Config.csr_max_concurrent // 0)}' <<<"$cfg")"
  fi
  log "removing Consul CSR limits (saved: $(jq -c '.values.csr_saved' "$STATE"))"
  consul-ca-limits.sh 0 0 >/dev/null
}
limits_restore() {
  local saved
  saved=$(jq -c '.values.csr_saved // empty' "$STATE")
  [ -n "$saved" ] || return 0 # nothing saved: limits were never removed
  log "restoring Consul CSR limits: $saved"
  consul-ca-limits.sh "$(jq -r .rate <<<"$saved")" "$(jq -r .concurrent <<<"$saved")" >/dev/null &&
    sset '.values.csr_saved' null
}

# --- guardrails over a test window --------------------------------------------
guardrails() { # guardrails <start_ms> <end_ms> [vault min failure tolerance, default 2] -> JSON
  local prom s e w vmin=${3:-2}
  prom=$(prom_url 2>/dev/null) || { echo null; return; }
  s=$(($1 / 1000)); e=$(($2 / 1000)); w=$((e - s))
  [ "$w" -gt 0 ] || { echo null; return; }
  q() { prom_query "$prom" "$1" "$e" | jq -r '.[0].value[1] // "null"'; }
  local scan
  scan=$(prom_query "$prom" "max by (instance) (max_over_time(perf_scanner_active[${w}s])) > 0" "$e" | jq -c '[.[].metric.instance] | sort' 2>/dev/null || echo '[]')
  jq -n -c --argjson scan "${scan:-[]}" \
    --argjson ce "$(q "sum(increase(consul_raft_state_leader[${w}s]))")" \
    --argjson ve "$(q "sum(changes(vault_core_active[${w}s])) / 2")" \
    --argjson cf "$(q "min(min_over_time(consul_autopilot_failure_tolerance[${w}s]))")" \
    --argjson vf "$(q "min(min_over_time(vault_autopilot_failure_tolerance[${w}s]))")" \
    --argjson vmin "$vmin" \
    '{consul_elections: ($ce | if . then (. | round) else . end), vault_leader_changes: ($ve | if . then (. | round) else . end),
      consul_min_failure_tolerance: $cf, vault_min_failure_tolerance: $vf}
     | .ok = ((.consul_elections // 0) == 0 and (.vault_leader_changes // 0) == 0
              and (.consul_min_failure_tolerance // 2) >= 2 and (.vault_min_failure_tolerance // $vmin) >= $vmin)
     | .scanner_hosts = $scan'
}

# --- stress.json helpers --------------------------------------------------------
stress_file() { echo "$RESULTS_DIR/$1-$PERF_NODE-stress-$2/stress.json"; }
stress_values() { # -> {last_pass, first_fail, stop_reason, knee}
  # Invalid steps (load generator out of memory) are neither a pass nor a fail.
  jq -c '{last_pass: .last_pass_rate, first_fail: ([.steps[] | select((.pass | not) and (.invalid | not)) | .rate] | first),
          invalid_rate, stop_reason, knee: .knee_between}' "$1"
}
midpoint() { # midpoint <values-json> -> rate or empty
  jq -r 'if .last_pass and .first_fail then ((.last_pass + .first_fail) / 2 | floor)
         elif .first_fail then (.first_fail / 2 | floor) else empty end' <<<"$1"
}

# --- tests ------------------------------------------------------------------------
settle() {
  local ids out tries=0 prom cpu el quiet=false
  if [ "$SETTLE_APT" = 1 ]; then
    ids=$(project_instances)
    log "settle: running due apt jobs on $(wc -w <<<"$ids") nodes and waiting for dpkg locks"
    out=$(ssm_run 1800 'systemctl start apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
for i in $(seq 1 240); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || break; sleep 5; done
echo "$(hostname) cloud-init=$(cloud-init status | awk "{print \$2}") dpkg-lock=$(fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && echo held || echo free)"' $ids)
    echo "$out" >> "$DIR/run.log"
    sset '.values.settle.apt' "$(jq -n -c --arg o "$out" '{nodes: ($o | split("\n") | map(select(length > 0)) | length),
      all_free: ($o | test("dpkg-lock=held") | not), all_success: ($o | test("\\[(Failed|TimedOut|Timeout|Cancelled)\\]") | not)}')"
  fi
  prom=$(prom_url)
  local waited=0 wait_max scan
  wait_max=$(to_secs "$SETTLE_SCANNER_WAIT")
  while :; do
    scan=$(prom_query "$prom" 'max by (instance) (max_over_time(perf_scanner_active[2m])) > 0' "$(date +%s)" | jq -r '[.[].metric.instance] | join(",")')
    [ -z "$scan" ] && break
    [ "$waited" -ge "$wait_max" ] && { log "settle: WARNING scanner still active on $scan after $SETTLE_SCANNER_WAIT; continuing"; break; }
    [ "$waited" -eq 0 ] && log "settle: waiting for security scanner(s) to finish on: $scan"
    sleep 60; waited=$((waited + 60))
  done
  [ "$waited" -gt 0 ] && log "settle: waited $((waited / 60)) min for scanners"
  sset '.values.settle.scanner_wait_min' "$((waited / 60))"
  while [ "$tries" -lt 3 ]; do
    idle settle "$( [ "$tries" -eq 0 ] && echo "$SETTLE_IDLE" || echo 5m)"
    cpu=$(prom_query "$prom" 'max(avg_over_time((100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",role!="monitoring"}[1m]))))[5m:15s]))' "$(date +%s)" | jq -r '.[0].value[1] // "0" | tonumber | . * 10 | round / 10')
    el=$(prom_query "$prom" 'sum(increase(consul_raft_state_leader[5m])) + sum(changes(vault_core_active[5m]))' "$(date +%s)" | jq -r '.[0].value[1] // "0" | tonumber | round')
    scan=$(prom_query "$prom" 'max by (instance) (max_over_time(perf_scanner_active[5m])) > 0' "$(date +%s)" | jq -r '[.[].metric.instance] | join(",")')
    tries=$((tries + 1))
    log "settle: check $tries: busiest host CPU (5m avg) ${cpu}%, elections/leader changes $el, scanner active: ${scan:-none}"
    if awk -v c="$cpu" -v m="$SETTLE_MAX_CPU" 'BEGIN { exit !(c < m) }' && [ "$el" -eq 0 ] && [ -z "$scan" ]; then quiet=true; break; fi
  done
  sset '.values.settle.quiet' "$(jq -n -c --argjson q "$quiet" --argjson c "$cpu" --argjson e "$el" --argjson t "$tries" --arg sc "$scan" \
    '{quiet: $q, busiest_cpu_pct: $c, elections: $e, checks: $t, scanner_hosts: $sc}')"
  [ "$quiet" = true ] || log "settle: WARNING not quiet after $tries checks; continuing (recorded in RESULTS.md)"
}


# T1/T2 sign on a synthetic Consul-shaped mount (pki-perf-mount.sh) with
# T1_CONNS independent clients, so the NLB spreads the load across every Vault
# node. (vault-benchmark multiplexes all workers over one HTTP/2 connection,
# which the NLB pins to a single node.)
t1() {
  pki-perf-mount.sh create
  MODES=multi LABEL="T1 Vault PKI baseline" CONCURRENCY="$T1_WORKERS" MULTI_CONNS="$T1_CONNS" \
    STEP="$T1_STEP" STEP_WARMUP="$T1_WARMUP" SIGN_PATH=pki_perf/sign/leaf-nostore SIGN_TOKEN="$VAULT_TOKEN" \
    RUN_ID="$PLAN-t1" connection-test.sh
  local res="$RESULTS_DIR/$PLAN-t1-$PERF_NODE-connection-test/connection-test.json"
  local knee
  knee=$(jq -c '[.steps[] | select(.errors == 0)] | sort_by(.concurrency) as $l
    | ([range(1; $l | length) | select($l[.].rps < 1.1 * $l[. - 1].rps)] | first) as $i
    | (if $i then $l[$i - 1] else $l[-1] end)
    | {workers: .concurrency, rps: (.rps | . * 10 | round / 10), p99_ms: .latency_ms.p99, vault_nodes_serving}' "$res")
  sset '.values.t1' "$(jq -c --slurpfile r "$res" '{knee: ., levels: [$r[0].steps[] | {workers: .concurrency,
      rps: (.rps | . * 10 | round / 10), p99_ms: .latency_ms.p99, errors, vault_nodes_serving, requests_by_vault_node}]}' <<<"$knee")"
  log "T1 knee: $knee"
}

t2() {
  local w
  w=$(sget '.values.t1.knee.workers')
  [ -n "$w" ] || { w=64; log "T2: no T1 knee recorded; using WORKERS=$w"; }
  pki-perf-mount.sh create
  MODES=multi LABEL="T2 store" CONCURRENCY="$w" MULTI_CONNS="$T1_CONNS" STEP="$T1_STEP" STEP_WARMUP="$T1_WARMUP" \
    SIGN_PATH=pki_perf/sign/leaf-store SIGN_TOKEN="$VAULT_TOKEN" RUN_ID="$PLAN-t2" connection-test.sh
  sset '.values.t2' "$(jq -c --argjson w "$w" '.multi_max // {} | {workers: $w, rps: ((.rps // 0) | . * 10 | round / 10),
      p99_ms: .p99, vault_nodes_serving}' "$RESULTS_DIR/$PLAN-t2-$PERF_NODE-connection-test/connection-test.json")"
  # Drop the stored certificates so later tests start from the same Raft state.
  pki-perf-mount.sh destroy | tee -a "$DIR/run.log"
}

t3() {
  env ${T3_START:+START=$T3_START} ${T3_MAX:+MAX=$T3_MAX} RUN_ID="$PLAN-t3" \
    stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
  sset '.values.t3' "$(stress_values "$(stress_file "$PLAN-t3" vault-sign-consul-mount)")"
}

t3c() {
  CONCURRENCY="$T3C_CONCURRENCY" MULTI_CONNS="$T3C_MULTI_CONNS" STEP="$T3C_STEP" RUN_ID="$PLAN-t3c" connection-test.sh
  sset '.values.t3c' "$(jq -c '{single_max, multi_max, single_to_multi_ratio}' \
    "$RESULTS_DIR/$PLAN-t3c-$PERF_NODE-connection-test/connection-test.json")"
}

t5() {
  limits_remove
  trap limits_restore EXIT
  env ${T5_START:+START=$T5_START} ${T5_MAX:+MAX=$T5_MAX} RUN_ID="$PLAN-t5" \
    stress-k6.sh /opt/perf/k6/consul-leaf.js
  limits_restore
  trap - EXIT
  sset '.values.t5' "$(stress_file "$PLAN-t5" consul-leaf | xargs -I{} jq -c '{last_pass: .last_pass_rate,
      first_fail: ([.steps[] | select((.pass | not) and (.invalid | not)) | .rate] | first), invalid_rate,
      stop_reason, knee: .knee_between,
      loadgen_min_mem_pct: ([.steps[].loadgen_min_mem_pct // empty] | min),
      max_consul_vault_connections: ([.steps[].sign_nodes.consul_vault_connections_max // empty] | max)}' {})"
}

t6() {
  RUN_ID="$PLAN-t6" RATE="$T6_RATE" BASELINE="${T6_BASELINE:-1m}" COOLDOWN="${T6_COOLDOWN:-1m}" \
    RAMP="${T6_RAMP:-30s}" HOLD="${T6_HOLD:-2m}" IDLE="${T6_IDLE:-150s}" signing-distribution.sh
  sset '.values.t6' "$(jq -c '{expected_behaviour, busiest_node_changed_after_idle,
      runs: [.runs[] | {label, verdict, nodes_serving}]}' \
    "$RESULTS_DIR/$PLAN-t6-$PERF_NODE-signing-distribution/distribution.json")"
}

refine() { # refine <id> <source values key> <script> <limits: yes|no>
  local id=$1 src=$2 script=$3 lim=$4 vals rate rc dir
  vals=$(sget ".values.$src | tojson")
  rate=$(midpoint "${vals:-{\}}")
  if [ -z "$rate" ]; then
    log "$id: no pass/fail boundary in $src ($(jq -r '.stop_reason // "no data"' <<<"${vals:-{\}}")); skipped"
    sset ".values.$id" '{"skipped": true}'
    return 0
  fi
  if [ "$lim" = yes ]; then limits_remove; trap limits_restore EXIT; fi
  case "$script" in *consul-leaf.js) restart_consul_agent ;; esac
  set +e
  RUN_ID="$PLAN-$id" RATE="$rate" run-k6.sh "$script"
  rc=$?
  set -e
  if [ "$lim" = yes ]; then limits_restore; trap - EXIT; fi
  dir="$RESULTS_DIR/$PLAN-$id-$PERF_NODE-k6-$(basename "$script" .js)"
  # Same pass criterion as a stress step: thresholds pass AND >= MIN_ACHIEVED delivered.
  sset ".values.$id" "$(jq -c --argjson rate "$rate" --argjson rc "$rc" --argjson min "${MIN_ACHIEVED:-0.95}" '.metrics as $m
    | ([$m | to_entries[] | select(.key | startswith("http_req_duration{name:"))][0].value.values) as $d
    | ($m.iterations.values.count // 0) as $it | ($m.dropped_iterations.values.count // 0) as $dr
    | {rate: $rate, thresholds: (if $rc == 0 then "pass" elif $rc == 99 then "fail" elif $rc == 98 then "invalid" else "error" end),
       delivered: (if ($it + $dr) > 0 then ($it / ($it + $dr) * 1000 | round / 1000) else 0 end),
       p99_ms: ($d["p(99)"] | . * 100 | round / 100)}
    | .pass = (.thresholds == "pass" and .delivered >= $min)' "$dir/summary.json" |
    jq -c --argjson m "$(cat "$dir/loadgen-mem-min-pct" 2>/dev/null || echo null)" '. + {loadgen_min_mem_pct: $m}')"
}
t3r() { refine t3r t3 /opt/perf/k6/vault-sign-consul-mount.js no; }
t5r() { refine t5r t5 /opt/perf/k6/consul-leaf.js yes; }

raft_nonvoters() { # count of Vault Raft non-voters
  vault operator raft list-peers -format=json 2>/dev/null | jq '[.data.config.servers[] | select(.voter | not)] | length' 2>/dev/null || echo 0
}
t9v() {
  local start up nv ids want n=0
  start=$(sget '.values.t3.last_pass')
  ids=$(project_instances "Name=tag:Role,Values=vault" "Name=tag:Voter,Values=false")
  want=$(wc -w <<<"$ids")
  if [ "$want" -eq 0 ]; then
    log "T9-V: no Vault non-voter instances (set vault_non_voter_count, ideally with vault_non_voters_start = false); skipped"
    sset '.values.t9v' '{"skipped": true}'
    return 0
  fi
  nv=$(raft_nonvoters)
  if [ "$nv" -lt "$want" ]; then
    log "T9-V: starting Vault on $want held non-voter(s)"
    ssm_run 300 'systemctl enable --now vault && sleep 5 && systemctl is-active vault' $ids | tee -a "$DIR/run.log"
    until [ "$(raft_nonvoters)" -ge "$want" ]; do
      n=$((n + 1)); [ "$n" -gt 60 ] && { log "T9-V: non-voters did not join within 10 minutes"; return 1; }
      sleep 10
    done
    log "T9-V: $(raft_nonvoters) non-voter(s) joined; letting them settle"
    idle "non-voter settle" 5m
  fi
  up=$(prom_query "$(prom_url)" 'count(up{job="vault"} == 1)' "$(date +%s)" | jq -r '.[0].value[1] // 0')
  env ${start:+START=$start} ${T3_MAX:+MAX=$T3_MAX} RUN_ID="$PLAN-t9-t3" stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
  CONCURRENCY="$T3C_CONCURRENCY" MULTI_CONNS="$T3C_MULTI_CONNS" STEP="$T3C_STEP" RUN_ID="$PLAN-t9-t3c" connection-test.sh
  sset '.values.t9v' "$(jq -c -n --argjson s "$(stress_values "$(stress_file "$PLAN-t9-t3" vault-sign-consul-mount)")" \
    --argjson c "$(jq -c '{single_max, multi_max, single_to_multi_ratio}' "$RESULTS_DIR/$PLAN-t9-t3c-$PERF_NODE-connection-test/connection-test.json")" \
    '{t3: $s, t3c: $c, vault_targets_up: '"$up"', non_voters: '"$(raft_nonvoters)"'}')"
}

# jq def shared by T11: one stress.json -> the fields T11 keeps per run.
T11_JQ="$DIR/t11.jq"
cat > "$T11_JQ" <<'JQ'
def r2: if . == null then null else . * 100 | round / 100 end;
def t11_run: {last_pass: .last_pass_rate,
  first_fail: ([.steps[] | select((.pass | not) and (.invalid | not)) | .rate] | first), stop_reason,
  steps: [.steps[] | {rate, pass, delivered: (.delivered * 1000 | round / 1000), failed_rate, p50_ms: (.p50_ms | r2), p99_ms: (.p99_ms | r2),
    raft: .vault_raft, leader: .leader_cost.leader, leader_az: .leader_cost.leader_az,
    tx_bytes_per_write: .leader_cost.tx_bytes_per_write, cpu_ms_per_write: .leader_cost.cpu_ms_per_write}]};
JQ

# T11: Vault Raft commit latency at <N> voters. Shrinks to N first if needed.
t11() { # t11 <voters> [id]
  local n=$1 id=${2:-t11v$1} st have nv kv
  sset ".values[\"$id\"]" null # no stale guardrail window from an earlier attempt
  st=$(vault-raft-voters.sh status)
  have=$(jq -r .voters <<<"$st"); nv=$(jq -r .non_voters <<<"$st")
  if [ "$nv" -gt 0 ]; then
    log "$id: $nv Vault non-voter(s) in Raft would add replication load; T11 needs a build without them"; return 1
  fi
  if [ "$(sget '.tests.t11grow.status')" = failed ]; then
    log "$id: t11grow failed, so Vault doesn't have the 7 voters T11 needs; see run.log"; return 1
  fi
  if [ "$id" != t11smoke ] && [ "$(sget '.tests.t11smoke.status')" = failed ]; then
    log "$id: t11smoke failed; fix the measurement it flagged (see RESULTS.md), then resume"; return 1
  fi
  if [ "$have" -lt "$n" ]; then
    log "$id: Vault has $have voters, need >= $n (build with vault_voter_count = 7)"; return 1
  fi
  # Same starting state at every size: a fresh, empty KV mount of its own. Earlier
  # sizes' mounts are left in place: unmounting deletes every key through Raft
  # (slow), and a cancelled unmount hung the active node's API in testing.
  KV_MOUNT="kv_perf_$id"
  export KV_MOUNT
  kv-perf-mount.sh create 2>&1 | tee -a "$DIR/run.log"
  if [ "$have" -gt "$n" ]; then
    log "$id: shrinking Vault from $have to $n voters"
    vault-raft-voters.sh shrink "$n" 2>&1 | tee -a "$DIR/run.log"
    idle "$id resize settle" "$T11_RESIZE_SETTLE" # NLB health checks and Autopilot catch up
  fi
  st=$(vault-raft-voters.sh status)
  log "$id: $(jq -c . <<<"$st")"
  # Guardrails cover the measurement only (the resize briefly lowers failure tolerance).
  sset ".values[\"$id\"]" "$(jq -c --argjson ms "$(now_ms)" '{cluster: ., measure_start_ms: $ms,
      expected_failure_tolerance: ((.voters - 1) / 2 | floor)}' <<<"$st")"

  # One chained timeline per size, like T3/T5: one baseline (the KV stress's),
  # KV steps -> payload sweep -> failover back to back, one cooldown (failover's).
  local r b kvruns='[]' payload='[]' sf
  # Every run below skips its own Grafana export (EXPORT=0); t11_export makes
  # one export of the whole size at the end, like a chained stress test.
  # KV grid, T11_KV_REPEATS times (only the first has a baseline): run-to-run spread.
  for r in $(seq 1 "$T11_KV_REPEATS"); do
    env RATES="$T11_KV_RATES" RAMP="$T11_RAMP" HOLD="$T11_HOLD" P99_MS="$T11_KV_P99_MS" COOLDOWN=0 EXPORT=0 \
      BASELINE="$([ "$r" -eq 1 ] && echo "$BASELINE" || echo 0)" RUN_ID="$PLAN-$id-kv$r" \
      stress-k6.sh /opt/perf/k6/vault-kv-write.js
    sf=$(stress_file "$PLAN-$id-kv$r" vault-kv-write)
    kvruns=$(jq -c --slurpfile f "$sf" "$(cat "$T11_JQ") . + [\$f[0] | t11_run]" <<<"$kvruns")
  done
  # Payload sweep, repeated like the grid: bigger entries multiply what the
  # leader sends to each follower.
  for r in $(seq 1 "$T11_KV_REPEATS"); do
    for b in $T11_PAYLOADS; do
      env RATES="$T11_PAYLOAD_RATE" RAMP="$T11_RAMP" HOLD="$T11_HOLD" P99_MS="$T11_KV_P99_MS" BASELINE=0 COOLDOWN=0 EXPORT=0 \
        VALUE_BYTES="$b" KEYS=200 RUN_ID="$PLAN-$id-kv${b}b$r" stress-k6.sh /opt/perf/k6/vault-kv-write.js
      sf=$(stress_file "$PLAN-$id-kv${b}b$r" vault-kv-write)
      payload=$(jq -c --slurpfile f "$sf" --argjson b "$b" --argjson r "$r" \
        "$(cat "$T11_JQ") . + [\$f[0] | t11_run | .steps[0] + {value_bytes: \$b, repeat: \$r}]" <<<"$payload")
    done
  done
  kv=$(jq -c -n --argjson runs "$kvruns" --argjson pl "$payload" '{runs: $runs, payload: $pl}')

  sset ".values[\"$id\"]" "$(jq -c --argjson kv "$kv" '. + {kv: $kv}' <<<"$(sget ".values[\"$id\"] | tojson")")"

  # Failover last: it elects new leaders on purpose, so the guardrails end here.
  sset ".values[\"$id\"].measure_end_ms" "$(now_ms)"
  REPEATS="$T11_FAILOVER_REPEATS" FREEZE="$T11_FREEZE" BASELINE=0 EXPORT=0 RUN_ID="$PLAN-$id-failover" vault-failover-test.sh
  sset ".values[\"$id\"].failover" "$(jq -c '{new_active_s, write_gap_s, healthy_s, failed_writes,
      detected_s, elected_s, active_s, old_stepdown_s,
      repeats: [.repeats[] | {old_active, new_active, new_active_s, write_gap_s, failed_writes, detected_s, elected_s, active_s}]}' \
    "$RESULTS_DIR/$PLAN-$id-failover-$PERF_NODE-failover/failover.json")"
  t11_export "$id"
}

# t11_export <id>: one Grafana export of a whole T11 size, from every run's
# phases.json in order. Phases keep their kind first (steady-..., warmup-...) so
# stats.md treats them like a chained stress test's: steady-kv1-r200,
# steady-kv16384b1-r400, failover-1, ...
t11_export() {
  local id=$1 out="$RESULTS_DIR/$PLAN-$1-$PERF_NODE-t11" d label
  mkdir -p "$out"
  PHASES="[]"
  for d in $(ls -d "$RESULTS_DIR/$PLAN-$id"-kv*-"$PERF_NODE"-stress-* \
    "$RESULTS_DIR/$PLAN-$id-failover-$PERF_NODE-failover" 2>/dev/null); do
    [ -f "$d/phases.json" ] || continue
    label=$(basename "$d" | sed -E "s/^$PLAN-$id-//; s/-$PERF_NODE-.*//")
    PHASES=$(jq -c --arg l "$label" --argjson acc "$PHASES" '$acc + map(
        if .name == "baseline" or .name == "cooldown" or (.name | startswith("failover")) then .
        else .name |= (split("-") as $p | ([$p[0], $l] + $p[1:]) | join("-")) end)' "$d/phases.json")
  done
  PHASES=$(jq -c 'sort_by(.start)' <<<"$PHASES")
  echo "$PHASES" | jq . > "$out/phases.json"
  echo "{\"tool\":\"t11\",\"run_id\":\"$PLAN-$id\",\"node\":\"$PERF_NODE\"}" > "$out/params.json"
  export_grafana "$out" "T11 $id ($PLAN)"
  upload_results "$out"
}
# t11smoke: a short T11 at the current size (no shrink), then checks that every
# measurement T11 depends on came back. Hard checks fail the test (and so stop
# t11v*); soft ones are recorded as warnings in RESULTS.md.
t11smoke() {
  local n v
  n=$(vault-raft-voters.sh status | jq -r .voters)
  export BASELINE=1m COOLDOWN=1m
  T11_RAMP=30s T11_HOLD=1m T11_KV_RATES="200 800" T11_KV_REPEATS=1 T11_PAYLOADS=16384 \
    T11_FAILOVER_REPEATS=1 T11_FREEZE=45s t11 "$n" t11smoke
  v=$(sget '.values.t11smoke | tojson')
  sset '.values.t11smoke.checks' "$(jq -c '(.kv.runs[0].steps[0] // {}) as $s | {
      hard: {
        autopilot_fields: (.cluster.healthy != null and .cluster.failure_tolerance != null),
        # Vault batches concurrent writes into fewer Raft applies (0.68 per KV v2 write at
        # 200/s), so this only rules out "almost nothing reached Raft" (e.g. a refused mount).
        writes_reach_raft: (($s.failed_rate // 1) < 0.01 and ($s.raft.applies_per_s // 0) >= 0.25 * ($s.rate // 1e9)),
        leader_placement: (.cluster.leader_az != null and .cluster.leader_az_peers != null),
        commit_time: ($s.raft.commit_mean_ms != null and $s.raft.commit_p99_ms != null),
        leader_cost: ($s.tx_bytes_per_write != null and $s.cpu_ms_per_write != null),
        failover_timing: (.failover.new_active_s.median != null and .failover.write_gap_s.median != null)},
      soft: {
        raft_applies_metric: ($s.raft.applies_per_s != null),
        failover_log_stages: (.failover.elected_s.median != null and .failover.active_s.median != null),
        # Whole-second write gaps mean k6 ignored K6_CSV_TIME_FORMAT (gap resolution 1 s).
        write_gap_ms_resolution: ((.failover.write_gap_s.median // 0) | . != (. | floor))},
      leader_kb_per_write: (($s.tx_bytes_per_write // 0) / 1024 | . * 100 | round / 100)}' <<<"$v")"
  log "t11smoke checks: $(sget '.values.t11smoke.checks | tojson')"
  [ "$(sget '[.values.t11smoke.checks.hard[]] | all')" = true ]
}
# t11grow (Stage 4): turn T9-V's non-voters into voters, so T11 can follow the
# main plan on the same build. Records how long each took to join Raft and to be
# promoted by Autopilot (server_stabilization_time after it's healthy).
t11grow() {
  local st out
  st=$(vault-raft-voters.sh status)
  if [ "$(jq -r .voters <<<"$st")" -ge 7 ] && [ "$(jq -r .non_voters <<<"$st")" -eq 0 ]; then
    log "t11grow: Vault already has $(jq -r .voters <<<"$st") voters; nothing to convert"
    sset '.values.t11grow' '{"skipped": true}'
    return 0
  fi
  log "t11grow: $(jq -r '"\(.voters) voters, \(.non_voters) non-voter(s)"' <<<"$st"); converting the non-voters"
  out=$(vault-raft-voters.sh convert 2> >(tee -a "$DIR/run.log" >&2)) || { log "t11grow: convert failed"; return 1; }
  sset '.values.t11grow' "$out"
  log "t11grow: $(jq -c '{nodes, voters: .cluster.voters, az_spread: .cluster.az_spread, failure_tolerance: .cluster.failure_tolerance}' <<<"$out")"
  [ "$(jq -r .cluster.voters <<<"$out")" -ge 7 ] || { log "t11grow: only $(jq -r .cluster.voters <<<"$out") voters; T11 needs 7"; return 1; }
  idle "t11grow settle" "$T11_RESIZE_SETTLE" # NLB health checks and Autopilot catch up
}
t11v7() { t11 7; }
t11v5() { t11 5; }
t11v3() { t11 3; }

run_test() { # run_test <id> <description>
  local id=$1 s e
  if done_test "$id"; then log "$id: already done, skipping"; return 0; fi
  log "=== $id: $2"
  sset ".tests[\"$id\"]" '{"status": "running"}'
  s=$(now_ms)
  if ( "$id" ); then st=done; else st=failed; fi
  e=$(now_ms)
  # A test may narrow its guardrail window (T11: after the resize, before the failover) and expect another failure tolerance.
  g=$(guardrails "$(sget ".values[\"$id\"].measure_start_ms // $s")" "$(sget ".values[\"$id\"].measure_end_ms // $e")" "$(sget ".values[\"$id\"].expected_failure_tolerance")")
  sset ".tests[\"$id\"]" "$(jq -n -c --arg st "$st" --argjson s "$s" --argjson e "$e" --argjson g "$g" \
    '{status: $st, start_ms: $s, end_ms: $e, minutes: (($e - $s) / 60000 | round), guardrails: $g}')"
  summarise.sh "$PLAN-${id/t9v/t9}" >/dev/null 2>&1 || true
  log "$id: $st ($(sget ".tests[\"$id\"].minutes") min, guardrails ok: $(sget ".tests[\"$id\"].guardrails.ok"))"
  results_md
  upload_state
}

results_md() {
  jq -r '. as $root
    | def g: (if .guardrails == null then "?" elif .guardrails.ok then "ok" else "⚠️ \(.guardrails | del(.scanner_hosts) | tojson)" end)
             + (if ((.guardrails.scanner_hosts // []) | length) > 0 then " · 🔍 scanner: \(.guardrails.scanner_hosts | join(", "))" else "" end);
      def v(k): $root.values[k] // {};
      # Booleans need care: jq treats false like null in `//`, so `false // "?"` gives "?".
      def b(x): if x == null then "?" else (x | tostring) end;
    "# Results: \(.plan)\n",
    "| Test | Status | Minutes | Guardrails | Key result |", "|---|---|---:|---|---|",
    (.tests | to_entries[] | . as $t | $t.key as $k
      | "| \($k) | \($t.value.status) | \($t.value.minutes // "-") | \($t.value | g) | " +
        (if $k == "t1" then "knee \(v("t1").knee.workers // "?") workers: \(v("t1").knee.rps // "?")/s, p99 \(v("t1").knee.p99_ms // "?") ms, \(v("t1").knee.vault_nodes_serving // "?") Vault node(s) serving"
         elif $k == "t2" then "store @ \(v("t2").workers // "?") workers: \(v("t2").rps // "?")/s, p99 \(v("t2").p99_ms // "?") ms, \(v("t2").vault_nodes_serving // "?") Vault node(s) serving"
         elif $k == "t3" or $k == "t5" then "last pass \(v($k).last_pass // "-")/s, first fail \(v($k).first_fail // "-")/s, knee \(v($k).knee // "-" | tostring)"
            + (if v($k).invalid_rate then ", **\(v($k).invalid_rate)/s invalid: load generator out of memory**" else "" end)
            + (if $k == "t5" then ", max Consul→Vault conns \(v("t5").max_consul_vault_connections // "-")" else "" end)
         elif $k == "t3c" then "single \(v("t3c").single_max.rps // 0 | round)/s vs multi \(v("t3c").multi_max.rps // 0 | round)/s (ratio \(v("t3c").single_to_multi_ratio // "?"))"
         elif $k == "t6" then "expected behaviour: \(v("t6").expected_behaviour // "?"), node changed after idle: \(b(v("t6").busiest_node_changed_after_idle))"
         elif $k == "t3r" or $k == "t5r" then (if v($k).skipped then "skipped (no boundary)"
            elif v($k).thresholds == "invalid" then "\(v($k).rate // "?")/s: **INVALID** (load generator out of memory)"
            else "\(v($k).rate // "?")/s: **\(if v($k).pass then "PASS" else "FAIL" end)** (thresholds \(v($k).thresholds // "?"), delivered \(v($k).delivered // "?"), p99 \(v($k).p99_ms // "?") ms)" end)
         elif $k == "settle" then "waited \(v("settle").scanner_wait_min // 0) min for scanners; quiet: \(b(v("settle").quiet.quiet)) (busiest CPU \(v("settle").quiet.busiest_cpu_pct // "?")%, elections \(v("settle").quiet.elections // "?"), \(v("settle").quiet.checks // "?") check(s)); apt: \(v("settle").apt.nodes // "-") nodes, locks free \(b(v("settle").apt.all_free))"
         elif $k == "t11smoke" then (v("t11smoke").checks // {}) as $c
            | "hard checks: " + ([$c.hard // {} | to_entries[] | "\(.key) \(if .value then "ok" else "**FAILED**" end)"] | join(", "))
            + "; warnings: " + ([$c.soft // {} | to_entries[] | select(.value | not) | .key] | if length == 0 then "none" else join(", ") end)
            + "; leader \($c.leader_kb_per_write // "?") KB/write at 200/s"
         elif ($k | startswith("t11v")) then "\(v($k).cluster.voters // "?") voters (AZ \(v($k).cluster.az_spread // {} | [.[]] | map(tostring) | join("/")), failure tolerance \(v($k).cluster.failure_tolerance // "?")): KV last pass \(v($k).kv.runs // [] | map(.last_pass // "-" | tostring) | join(", "))/s; leader \(v($k).cluster.leader // "?") (\(v($k).cluster.leader_az_peers // "?") same-AZ voters); failover: new active \(v($k).failover.new_active_s.median // "?") s, write gap \(v($k).failover.write_gap_s.median // "?") s (median)"
         elif $k == "t11grow" and v("t11grow").skipped then "skipped (already 7 voters)"
         elif $k == "t11grow" then "\(v("t11grow").cluster.voters // "?") voters (AZ \(v("t11grow").cluster.az_spread // {} | [.[]] | map(tostring) | join("/"))); "
            + (v("t11grow").nodes // [] | map("\(.node) joined \(.joined_s) s, promoted \(.promoted_s) s (\(.join_to_promotion_s) s after joining)") | join("; "))
         elif $k == "t9v" and v("t9v").skipped then "skipped (no non-voters)"
         elif $k == "t9v" then "T3 last pass \(v("t9v").t3.last_pass // "-")/s (was \(v("t3").last_pass // "-")); T3c multi \(v("t9v").t3c.multi_max.rps // 0 | round)/s, single \(v("t9v").t3c.single_max.rps // 0 | round)/s"
         else "" end) + " |"),
    ([.values | to_entries[] | select((.key | startswith("t11v")) and .value.cluster.voters != null) | .value] | sort_by(-.cluster.voters) as $t
     | if ($t | length) == 0 then empty else
         # agg: mean over repeats, ± half the range (a single value as is).
         def agg(xs): ([xs | select(. != null)]) as $v
           | if ($v | length) == 0 then "-" elif ($v | length) == 1 then "\($v[0] | . * 100 | round / 100)"
             else "\($v | add / length | . * 100 | round / 100) ±\(($v | max) - ($v | min) | . / 2 * 100 | round / 100)" end;
         def at($r): [.kv.runs[]?.steps[]? | select(.rate == $r)];
         def mark: if any(.[]; .pass | not) then " ✗" else "" end;
         def kb: if . == null then null else . / 1024 | . * 100 | round / 100 end;
         ([$t[].kv.runs[]?.steps[]?.rate] | unique) as $rates
         | ($t | map(.cluster.voters) | min) as $nmin
         | "\n## T11: Vault Raft by voter count\n",
         "Leader placement: " + ($t | map("\(.cluster.voters) voters: \(.cluster.leader // "?") in \(.cluster.leader_az // "?") with \(.cluster.leader_az_peers // "?") same-AZ voter(s)") | join("; ")) + ".\n",
         "### Commit time (ms)\n",
         "Server: Raft commit mean / p99 on the active node. Client: KV write p99 (writes are forwarded to the active node). "
         + "Values are the mean over \($t[0].kv.runs | length) repeats ± half their range.\n",
         "| Rate/s | " + ($t | map("\(.cluster.voters)v commit mean | \(.cluster.voters)v commit p99 | \(.cluster.voters)v client p99") | join(" | ")) + " |",
         "|---:|" + ($t | map("---:|---:|---:|") | join("")),
         ($rates[] as $r | "| \($r) | " + ($t | map(at($r) as $s
           | "\(agg($s[].raft.commit_mean_ms)) | \(agg($s[].raft.commit_p99_ms)) | \(agg($s[].p99_ms))\($s | mark)") | join(" | ")) + " |"),
         "\n### Leader cost per write\n",
         "What the active node sends (KB) and spends (CPU ms) per write; it replicates each entry to N-1 followers, "
         + "so KB/write should scale about (N-1) : (\($nmin)-1). Ratio = KB/write over the \($nmin)-voter value at the same rate.\n",
         "| Rate/s | " + ($t | map("\(.cluster.voters)v KB/write | \(.cluster.voters)v CPU ms/write | \(.cluster.voters)v ratio") | join(" | ")) + " |",
         "|---:|" + ($t | map("---:|---:|---:|") | join("")),
         ($rates[] as $r
          | ([$t[] | select(.cluster.voters == $nmin) | at($r)[].tx_bytes_per_write | select(. != null)] | if length > 0 then add / length else null end) as $base
          | "| \($r) | " + ($t | map(at($r) as $s
              | ([$s[].tx_bytes_per_write | select(. != null)] | if length > 0 then add / length else null end) as $tx
              | "\(agg($s[].tx_bytes_per_write | kb)) | \(agg($s[].cpu_ms_per_write)) | "
                + (if $tx and $base and $base > 0 then "\($tx / $base * 100 | round / 100)×" else "-" end)) | join(" | ")) + " |"),
         "\n### Payload sweep (\($t[0].kv.payload[0].rate // "?")/s)\n",
         "| Value | " + ($t | map("\(.cluster.voters)v commit mean / p99 | \(.cluster.voters)v client p99 | \(.cluster.voters)v KB/write") | join(" | ")) + " |",
         "|---|" + ($t | map("---:|---:|---:|") | join("")),
         (($t[0].kv.payload[0].rate // null) as $pr | select($pr)
          | "| 1 KiB | " + ($t | map(at($pr) as $s
              | "\(agg($s[].raft.commit_mean_ms)) / \(agg($s[].raft.commit_p99_ms)) | \(agg($s[].p99_ms))\($s | mark) | \(agg($s[].tx_bytes_per_write | kb))") | join(" | ")) + " |"),
         (([$t[].kv.payload[]?.value_bytes] | unique)[] as $b
          | "| \($b / 1024) KiB | " + ($t | map([.kv.payload[]? | select(.value_bytes == $b)] as $s
              | "\(agg($s[].raft.commit_mean_ms)) / \(agg($s[].raft.commit_p99_ms)) | \(agg($s[].p99_ms))\($s | mark) | \(agg($s[].tx_bytes_per_write | kb))") | join(" | ")) + " |"),
         "\n### Failover\n",
         "| | " + ($t | map("\(.cluster.voters) voters") | join(" | ")) + " |",
         "|---|" + ($t | map("---:|") | join("")),
         "| failover: new active, median / max (s) | " + ($t | map(.failover | "\(.new_active_s.median // "-") / \(.new_active_s.max // "-")") | join(" | ")) + " |",
         "| failover: write gap, median / max (s) | " + ($t | map(.failover | "\(.write_gap_s.median // "-") / \(.write_gap_s.max // "-") (\(.failed_writes // "-") failed)") | join(" | ")) + " |",
         "| failover from logs: detected / elected / active, median (s) | " + ($t | map(.failover
              | "\(.detected_s.median // "-") / \(.elected_s.median // "-") / \(.active_s.median // "-")") | join(" | ")) + " |",
         "\n✗ = a step failed its thresholds (p99 or errors) or delivered < 95%. "
         + "Failover: SIGSTOP of the active node; new active = until another voter answers as active; "
         + "write gap = longest time with no successful write (20 writes/s through the NLB). "
         + "From the Vault logs: detected = first heartbeat timeout, elected = election won, active = post-unseal setup complete; "
         + "per-repeat timelines in <plan>-t11v<N>-failover-*/logs/repeat-<i>/timeline.log."
       end),
    "\n🔍 = a security scanner (perf_scanner_active) ran on those hosts during the test; consider re-running it.",
    "\nPer-test reports: s3://<bucket>/results/\(.plan)-<test>-summary/summary.md"' "$STATE" > "$DIR/RESULTS.md"
}

case "$CMD" in
start)
  if systemctl is-active --quiet "$UNIT"; then echo "$UNIT is already running"; exit 1; fi
  env_args=()
  for v in T1_WORKERS T1_CONNS T1_STEP T1_WARMUP T3_START T3_MAX T5_START T5_MAX T3C_CONCURRENCY T3C_MULTI_CONNS T3C_STEP T6_RATE T6_BASELINE \
    T6_COOLDOWN T6_RAMP T6_HOLD T6_IDLE T11_KV_RATES T11_KV_REPEATS T11_PAYLOADS T11_PAYLOAD_RATE T11_RAMP T11_HOLD T11_KV_P99_MS T11_RESIZE_SETTLE T11_FAILOVER_REPEATS T11_FREEZE BASELINE COOLDOWN RAMP HOLD WARMUP DURATION EXPORT START_RATE VUS MAX_VUS \
    P99_MS MAX_ERROR_RATE SETTLE_APT SETTLE_IDLE SETTLE_MAX_CPU SETTLE_SCANNER_WAIT MIN_ACHIEVED PLAN_TESTS MEM_GUARD_PCT; do
    [ -n "${!v:-}" ] && env_args+=("--setenv=$v=${!v}")
  done
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  sudo systemd-run --unit "$UNIT" --uid "$(id -u)" --gid "$(id -g)" --working-directory /opt/perf \
    "${env_args[@]}" /bin/bash -lc "/opt/perf/scripts/run-plan.sh run '$PLAN'"
  echo "started $UNIT; follow with: run-plan.sh status $PLAN   (or journalctl -fu $UNIT)"
  ;;
run)
  log "plan $PLAN starting on $PERF_NODE"
  limits_restore # a previous run stopped mid-T5 leaves limits removed
  for t in "settle:settle the cluster (apt jobs, idle, quiet check)" \
    "t1:Vault PKI baseline (no_store worker sweep, all nodes)" "t2:cost of storing certificates" \
    "t3:Vault cluster capacity on Consul's mount (stress)" "t3c:single vs multiple connections" \
    "t5:Consul leaf path, CSR limits removed (stress)" "t6:signing distribution" \
    "t3r:refinement near T3's ceiling" "t5r:refinement near T5's ceiling" \
    "t9v:Vault + non-voters: T3 from its last pass, then T3c" \
    "t11grow:Stage 4: convert the Vault non-voters to voters (7 voters)" \
    "t11smoke:T11 smoke check (short run at the current size, no shrink)" \
    "t11v7:Vault Raft latency, 7 voters" "t11v5:Vault Raft latency, 5 voters (shrinks Vault)" \
    "t11v3:Vault Raft latency, 3 voters (shrinks Vault)"; do
    if [ -n "$PLAN_TESTS" ] && ! grep -qw -- "${t%%:*}" <<<"$PLAN_TESTS"; then continue; fi
    run_test "${t%%:*}" "${t#*:}"
  done
  log "plan $PLAN complete; results in $DIR/RESULTS.md. Remember: terraform destroy when done."
  ;;
t9v)
  run_test t9v "Vault + 2 non-voters: T3 from its last pass, then T3c"
  ;;
stop)
  sudo systemctl stop "$UNIT" 2>/dev/null || true
  limits_restore
  echo "stopped $UNIT"
  ;;
status)
  echo "plan: $PLAN ($(systemctl is-active "$UNIT" 2>/dev/null || true))"
  jq -r '.tests | to_entries[] | "  \(.key): \(.value.status)\(if .value.minutes then " (\(.value.minutes) min)" else "" end)"' "$STATE"
  echo; tail -5 "$DIR/run.log" 2>/dev/null || true
  echo; [ -f "$DIR/RESULTS.md" ] && cat "$DIR/RESULTS.md"
  ;;
*)
  echo "usage: run-plan.sh start|status|stop|t9v|run [PLAN]" >&2
  exit 1
  ;;
esac
