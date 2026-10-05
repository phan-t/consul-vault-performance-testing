# Shared helpers for the run-* scripts.
set -euo pipefail
. /etc/profile.d/perf.sh
. /opt/perf/scripts/env.sh

RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}

# Idle windows around every test so the steady state can be compared with a
# known quiet baseline and recovery. EXPORT=auto exports Grafana only from
# loadgen-0 (server-side metrics are the same whichever node exports).
BASELINE=${BASELINE:-5m}
COOLDOWN=${COOLDOWN:-5m}
EXPORT=${EXPORT:-auto}
DASHBOARD_UID=${DASHBOARD_UID:-consul-vault-perf}

# Consul-shaped leaf CSR: EC P-256 + SPIFFE URI SAN.
make_csr() {
  local dir=$1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$dir/leaf.key" -out "$dir/leaf.csr" -subj "/CN=perf-vb" \
    -addext "subjectAltName=URI:spiffe://perf.consul/ns/default/dc/${CONSUL_DATACENTER}/svc/perf-vb" 2>/dev/null
}

upload_results() {
  local dir=$1
  aws s3 cp --recursive --only-show-errors \
    --exclude 'leaf.key' --exclude 'config.hcl' \
    "$dir" "s3://$PERF_BUCKET/results/$(basename "$dir")/"
  echo "results: $dir  ->  s3://$PERF_BUCKET/results/$(basename "$dir")/"
}

now_ms() { date +%s%3N; }

# vault_retry <cmd...>: retry a Vault admin call for up to 5 minutes. Just after
# a leader change (T11's failover and shrink), standbys briefly can't forward
# and redirect the client to the active node's IP, which the shared TLS
# certificate doesn't cover ("certificate is valid for 127.0.0.1"); a retry a
# few seconds later is forwarded normally.
vault_retry() {
  local i
  for i in $(seq 1 30); do
    "$@" && return 0
    [ "$i" -lt 30 ] && { echo "vault_retry: '$*' failed ($i/30); retrying in 10s" >&2; sleep 10; }
  done
  return 1
}

# to_secs 90s|5m|1h|0 -> seconds
to_secs() {
  local v=$1
  case "$v" in
  0 | "") echo 0 ;;
  *ms) echo 0 ;;
  *s) echo "${v%s}" ;;
  *m) echo $((${v%m} * 60)) ;;
  *h) echo $((${v%h} * 3600)) ;;
  *) echo "$v" ;;
  esac
}

# idle <label> <duration>: keep the load generator quiet (baseline/cooldown).
idle() {
  local secs
  secs=$(to_secs "$2")
  [ "$secs" -gt 0 ] || return 0
  echo "$(date -u +%H:%M:%S) $1: idle for $2"
  sleep "$secs"
}

# Phases for the export, collected as JSON: add_phase <name> <start_ms> <end_ms>
PHASES="[]"
add_phase() {
  [ "$2" -lt "$3" ] || return 0
  PHASES=$(jq -c --arg n "$1" --argjson s "$2" --argjson e "$3" '. + [{name: $n, start: $s, end: $e}]' <<<"$PHASES")
}

# Grafana reachable with valid credentials? (-f: fail on 401/5xx)
grafana_ok() { [ -n "${GRAFANA_PASS:-}" ] && curl -sf -o /dev/null --max-time 5 -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/user"; }

# annotate <text> <tags-csv> [time_ms] -> prints annotation id (empty on failure)
annotate() {
  grafana_ok || return 0
  local body
  body=$(jq -n --arg uid "$DASHBOARD_UID" --arg text "$1" --arg tags "$2" --argjson t "${3:-$(now_ms)}" \
    '{dashboardUID: $uid, time: $t, text: $text, tags: ($tags | split(","))}')
  curl -s --max-time 10 -u "$GRAFANA_USER:$GRAFANA_PASS" -H 'Content-Type: application/json' \
    -X POST "$GRAFANA_URL/api/annotations" -d "$body" | jq -r '.id // empty' 2>/dev/null || true
}

# annotate_end <id> [end_ms]: turn a point annotation into a region.
annotate_end() {
  [ -n "${1:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 -u "$GRAFANA_USER:$GRAFANA_PASS" -H 'Content-Type: application/json' \
    -X PATCH "$GRAFANA_URL/api/annotations/$1" -d "{\"timeEnd\": ${2:-$(now_ms)}}" || true
}

# export_grafana <out_dir> <title>: export the dashboard for the whole run
# window (first phase start -> last phase end) with per-phase stats.
export_grafana() {
  local out=$1 title=$2
  if [ "$EXPORT" = "auto" ] && [ "$PERF_NODE" != "loadgen-0" ]; then
    echo "grafana export: skipped on $PERF_NODE (EXPORT=auto exports from loadgen-0)"
    return 0
  fi
  [ "$EXPORT" = "0" ] && return 0
  if ! grafana_ok; then
    echo "grafana export: Grafana not reachable at $GRAFANA_URL; skipped"
    return 0
  fi
  echo "$PHASES" | jq . > "$out/phases.json"
  python3 /opt/perf/scripts/grafana-export.py --url "$GRAFANA_URL" --uid "$DASHBOARD_UID" \
    --from "$(jq '.[0].start' <<<"$PHASES")" --to "$(jq '.[-1].end' <<<"$PHASES")" \
    --phases "$out/phases.json" --out "$out/grafana" --title "$title" ||
    echo "grafana export failed (results are still saved)"
}

# --- Prometheus helpers (stress-k6.sh, signing-distribution.sh) --------------

# Duration such as 90s, 10m or 1h, in seconds (same as to_secs).
dur_s() { to_secs "$1"; }

# Sign requests on Consul's intermediate, per Vault node (route metric).
SIGN_METRIC='{__name__=~"vault_route_update_connect_.*_inter__count"}'

# Prometheus on the monitoring node: PROM_URL if set, else the monitoring DNS
# name (derived from PROM_RW_URL in env.sh), else the node found by EC2 tags.
prom_url() {
  if [ -n "${PROM_URL:-}" ]; then echo "$PROM_URL"; return; fi
  local base=${PROM_RW_URL%/api/v1/write} ip
  if [ -n "$base" ] && curl -sf -o /dev/null --max-time 5 "$base/-/ready"; then
    echo "$base"
    return
  fi
  ip=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=monitoring" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  if [ -z "$ip" ] || [ "$ip" = "None" ]; then
    echo "monitoring node not found; set PROM_URL" >&2
    return 1
  fi
  echo "http://$ip:9090"
}

# prom_query <url> <expr> <unix time>: instant query, prints .data.result
prom_query() {
  curl -sfG "$1/api/v1/query" --data-urlencode "query=$2" --data-urlencode "time=$3" | jq -c .data.result
}

# prom_range <url> <expr> <start> <end> <step seconds>: range query, prints .data.result
prom_range() {
  curl -sfG "$1/api/v1/query_range" --data-urlencode "query=$2" \
    --data-urlencode "start=$3" --data-urlencode "end=$4" --data-urlencode "step=$5" | jq -c .data.result
}

# vault_raft_stats <prom> <start s> <end s>: Vault Raft commit time (ms) and
# applies/s over a window, as JSON. commitTime is leader-only, so the mean comes
# from the summary's _sum/_count across all nodes (exact, survives a leader
# change); p50/p99 are the leader's quantiles averaged over the window, and
# p99_max their peak. Fields are null when the metric is missing.
vault_raft_stats() {
  local p=$1 s=$2 e=$3 w
  w=$(($3 - $2))
  [ "$w" -gt 0 ] || { echo null; return; }
  q() { prom_query "$p" "$1" "$e" | jq -c '.[0].value[1] // null | if . == null or . == "NaN" then null else (tonumber | . * 100 | round / 100) end' 2>/dev/null || echo null; }
  jq -n -c \
    --argjson mean "$(q "sum(increase(vault_raft_commitTime_sum[${w}s])) / sum(increase(vault_raft_commitTime_count[${w}s]))")" \
    --argjson p50 "$(q "max(avg_over_time((vault_raft_commitTime{quantile=\"0.5\"} >= 0)[${w}s:15s]))")" \
    --argjson p99 "$(q "max(avg_over_time((vault_raft_commitTime{quantile=\"0.99\"} >= 0)[${w}s:15s]))")" \
    --argjson p99max "$(q "max(max_over_time((vault_raft_commitTime{quantile=\"0.99\"} >= 0)[${w}s:15s]))")" \
    --argjson applies "$(q "sum(rate(vault_raft_apply[${w}s]))")" \
    --argjson lc "$(q "max(max_over_time((vault_raft_leader_lastContact{quantile=\"0.99\"} >= 0)[${w}s:15s]))")" \
    '{commit_mean_ms: $mean, commit_p50_ms: $p50, commit_p99_ms: $p99, commit_p99_max_ms: $p99max,
      applies_per_s: $applies, leader_last_contact_p99_max_ms: $lc}'
}

# vault_leader_cost <prom> <start s> <end s>: what the Vault active node (Raft
# leader) spent over a window, as JSON: network bytes sent per second and CPU
# cores busy. The leader sends every Raft entry to each of the N-1 followers,
# so per write these grow with the voter count. The leader is the node with the
# highest vault_core_active over the window (instance and az labels from EC2 SD).
vault_leader_cost() {
  local p=$1 s=$2 e=$3 w l az
  w=$(($3 - $2))
  [ "$w" -gt 0 ] || { echo null; return; }
  read -r l az < <(prom_query "$p" "topk(1, avg_over_time(vault_core_active[${w}s]))" "$e" |
    jq -r '.[0].metric | "\(.instance // "") \(.az // "")"' 2>/dev/null) || true
  [ -n "${l:-}" ] || { echo null; return; }
  q() { prom_query "$p" "$1" "$e" | jq -c '.[0].value[1] // null | if . == null or . == "NaN" then null else (tonumber | . * 1000 | round / 1000) end' 2>/dev/null || echo null; }
  jq -n -c --arg l "$l" --arg az "$az" \
    --argjson tx "$(q "sum(rate(node_network_transmit_bytes_total{job=\"node\",instance=\"$l\",device!~\"lo|docker.*|veth.*\"}[${w}s]))")" \
    --argjson rx "$(q "sum(rate(node_network_receive_bytes_total{job=\"node\",instance=\"$l\",device!~\"lo|docker.*|veth.*\"}[${w}s]))")" \
    --argjson cpu "$(q "sum(rate(node_cpu_seconds_total{job=\"node\",instance=\"$l\",mode!=\"idle\"}[${w}s]))")" \
    '{leader: $l, leader_az: $az, tx_bytes_per_s: $tx, rx_bytes_per_s: $rx, cpu_cores: $cpu}'
}

# --- SSM Run Command (run-plan.sh settle / T9-V, vault-raft-voters.sh) --------
project_instances() { # project_instances [extra EC2 filters...] -> instance IDs
  aws ec2 describe-instances --filters "Name=tag:Project,Values=$PERF_NAME" "Name=instance-state-name,Values=running" "$@" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}
ssm_run() { # ssm_run <timeout_s> <command> <instance-id>... -> prints "<id>: <output>" per instance
  local timeout=$1 cmd=$2 cid id st deadline
  shift 2
  [ $# -gt 0 ] || return 0
  cid=$(aws ssm send-command --instance-ids "$@" --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$cmd" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
    --comment "perf ${PLAN:-$RUN_ID}" --query Command.CommandId --output text)
  deadline=$(($(date +%s) + timeout + 120))
  for id in "$@"; do
    while :; do
      st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
      [ "$(date +%s)" -gt "$deadline" ] && { st=Timeout; break; }
      sleep 10
    done
    echo "$id [$st]: $(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null | tr '\n' ' ')"
  done
}

# steady_window <run dir>: "<start> <end>" (unix seconds) of the run's steady
# phase from phases.json. run-k6.sh returns only after its cooldown and Grafana
# export, so "now minus HOLD" is not the steady state.
steady_window() {
  jq -r '.[] | select(.name == "steady") | "\(.start / 1000 | floor) \(.end / 1000 | floor)"' "$1/phases.json"
}

# Restart the local Consul client agent and wait for it to rejoin. The agent
# caches every leaf consul-leaf.js fetches, so load tests start from a fresh
# agent. /v1/status/leader needs no ACL (consul info needs agent:read, which the
# perf token lacks) and only returns a leader once the agent has rejoined.
restart_consul_agent() {
  sudo systemctl restart consul
  local n=0
  until curl -sf --max-time 2 "$CONSUL_HTTP_ADDR/v1/status/leader" | grep -q '[0-9]'; do
    n=$((n + 1))
    [ "$n" -ge 90 ] && { echo "consul agent not back after 3 minutes" >&2; return 1; }
    sleep 2
  done
  sleep 10
}
