# Shared helpers for the replication campaign (T17, issue #23). Source me.
# Runs on the replication build's load generators (terraform-repl), which have
# no Consul: /etc/profile.d/perf.sh sets PERF_CLUSTERS (/etc/perf/clusters.json),
# VAULT_ADDR (the local cluster) and VAULT_CACERT.
set -euo pipefail
. /etc/profile.d/perf.sh

PLAN=${PLAN:-repl-1}
RES=${RES:-/opt/perf/results/$PLAN-repl}
mkdir -p "$RES"
STATE_DIR=/opt/perf/.repl
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

CLUSTERS="primary pr-sec primary-dr pr-sec-dr"
# loadgen-0 runs the campaign and owns events.jsonl; loadgen-1 writes its own.
if [ "$PERF_NODE" = loadgen-0 ]; then EVENTS="$RES/events.jsonl"; else EVENTS="$RES/events-$PERF_NODE.jsonl"; fi

now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
now_s() { date +%s; }
log() { echo "$(date -u +%H:%M:%S) $*" >&2; }
die() { log "ERROR: $*"; event error msg "$*"; exit 1; }

# event <name> [key value]...: one line in $RES/events.jsonl, the run's timeline.
event() {
  local name=$1 args=()
  shift
  while [ $# -ge 2 ]; do args+=(--arg "$1" "$2"); shift 2; done
  jq -cn --arg ts "$(now)" --arg event "$name" --arg node "$PERF_NODE" "${args[@]}" '$ARGS.named' >> "$EVENTS"
}

# cl <cluster> <field>: from clusters.json (region, role, dr_of, addr,
# cluster_addr, fqdn, join_tag, init_secret, bootstrap_param, tg_arn).
cl() { jq -er --arg c "$1" --arg f "$2" '.[$c][$f]' "$PERF_CLUSTERS"; }

# init_json <cluster>: the cluster's init secret (root token, recovery keys).
init_json() {
  aws secretsmanager get-secret-value --region "$(cl "$1" region)" --secret-id "$(cl "$1" init_secret)" \
    --query SecretString --output text
}

# token <cluster>: a root token valid on that cluster. Secondaries lose their
# own: setup.sh caches an admin token for the PR secondary (repl-admin
# AppRole login), and a DR replica only accepts DR operation tokens until it's promoted (then
# the primary's tokens work, because DR replicates them).
token() {
  local f="$STATE_DIR/token-$1"
  if [ ! -s "$f" ]; then (umask 077 && init_json "$1" | jq -r .root_token > "$f"); fi
  cat "$f"
}
forget_token() { rm -f "$STATE_DIR/token-$1"; }

# v <cluster> <vault args...>: the Vault CLI against a cluster's NLB.
v() {
  local c=$1
  shift
  VAULT_ADDR=$(cl "$c" addr) VAULT_TOKEN=${TOKEN_OVERRIDE:-$(token "$c")} vault "$@"
}

# api <cluster> <METHOD> <path> [json body] -> prints "<http code> <compact body>".
# For probes: never fails, so a refused write is a result, not an error.
api() {
  local c=$1 m=$2 p=$3 body=${4:-} out code
  local hdr=()
  out=$(mktemp)
  # TOKEN_OVERRIDE=none: no token (logins, and calls that carry a DR operation token).
  [ "${TOKEN_OVERRIDE:-}" = none ] || hdr=(-H "X-Vault-Token: ${TOKEN_OVERRIDE:-$(token "$c")}")
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time "${API_TIMEOUT:-15}" --cacert "$VAULT_CACERT" \
    -X "$m" ${hdr[@]+"${hdr[@]}"} -H 'Content-Type: application/json' \
    ${body:+--data "$body"} "$(cl "$c" addr)/v1/$p" || true)
  echo "${code:-000} $(jq -c . "$out" 2>/dev/null || tr -d '\n' < "$out" | head -c 300)"
  rm -f "$out"
}

# repl_status <cluster>: sys/replication/status (unauthenticated).
repl_status() {
  curl -s --max-time 10 --cacert "$VAULT_CACERT" "$(cl "$1" addr)/v1/sys/replication/status" | jq -c '.data // {}'
}

# repl_state <cluster> <dr|performance> -> state, e.g. stream-wals.
repl_state() { repl_status "$1" | jq -r --arg t "$2" '.[$t].state // "unknown"'; }

# wait_state <cluster> <dr|performance> <state> <timeout_s> -> seconds taken; 1 on timeout.
wait_state() {
  local c=$1 t=$2 want=$3 timeout=$4 s
  s=$(now_s)
  until [ "$(repl_state "$c" "$t" 2>/dev/null || echo unknown)" = "$want" ]; do
    [ $(($(now_s) - s)) -ge "$timeout" ] && return 1
    sleep 1
  done
  echo $(($(now_s) - s))
}

# wait_caught_up <secondary> <dr|performance> <its primary> <timeout_s> -> seconds; 1 on timeout.
# Caught up: state stream-wals, connection_state ready, and last_remote_wal
# at or past the primary's WAL index (last_performance_wal or last_dr_wal) when
# this was called. The state alone can read stream-wals before the connection
# is back.
wait_caught_up() {
  local s=$1 t=$2 p=$3 timeout=$4 field target start st
  field=last_performance_wal
  [ "$t" = dr ] && field=last_dr_wal
  target=$(repl_status "$p" | jq -r --arg t "$t" --arg f "$field" '.[$t][$f] // 0')
  start=$(now_s)
  while :; do
    st=$(repl_status "$s" 2>/dev/null || echo '{}')
    if jq -e --arg t "$t" --argjson w "${target:-0}" \
      '.[$t] | .state == "stream-wals" and (.connection_state // "ready") == "ready" and ((.last_remote_wal // 0) >= $w)' \
      <<<"$st" >/dev/null 2>&1; then
      echo $(($(now_s) - start))
      return 0
    fi
    [ $(($(now_s) - start)) -ge "$timeout" ] && return 1
    sleep 1
  done
}

# wait_healthy <cluster> <timeout_s>: active node answers (200, 429 or 473).
wait_healthy() {
  local c=$1 timeout=$2 s code
  s=$(now_s)
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$VAULT_CACERT" \
      "$(cl "$c" addr)/v1/sys/health?standbyok=true&perfstandbyok=true&drsecondarycode=200&performancestandbycode=200" || true)
    [ "$code" = "200" ] && return 0
    [ $(($(now_s) - s)) -ge "$timeout" ] && return 1
    sleep 5
  done
}

# sealed_ids <cluster> -> instance IDs of the nodes that report sealed.
sealed_ids() {
  local id ip
  while read -r id ip; do
    curl -s --max-time 5 --cacert "$VAULT_CACERT" --resolve "$(cl "$1" fqdn):8200:$ip" \
      "https://$(cl "$1" fqdn):8200/v1/sys/seal-status" | jq -e '.sealed == false' >/dev/null 2>&1 || echo "$id"
  done < <(nodes "$1")
}

# unseal_standbys <cluster>: after activation, update-primary, or a demote,
# the standbys log "encryption keys have changed out from underneath us ...
# must be unsealed again" and stay sealed: auto-unseal doesn't retry. A
# restart unseals them with the new keys (seen in the second repl-dry run).
unseal_standbys() {
  local c=$1 ids
  sleep 15
  ids=$(sealed_ids "$c" | xargs)
  if [ -n "$ids" ]; then
    log "unseal: restarting Vault on sealed $c nodes: $ids"
    event unseal_restart cluster "$c" nodes "$ids"
    ssm_run "$(cl "$c" region)" 120 "systemctl restart vault && sleep 5 && systemctl is-active vault" $ids >&2
  fi
  wait_unsealed "$c" 600 || die "$c still has sealed nodes: $(sealed_ids "$c" | xargs)"
}

# wait_unsealed <cluster> <timeout_s>: every node reports sealed=false, then 25 s
# for the NLB's health checks to catch up.
wait_unsealed() {
  local c=$1 timeout=$2 s ip sealed
  s=$(now_s)
  while :; do
    sealed=0
    for ip in $(node_ips "$c"); do
      curl -s --max-time 5 --cacert "$VAULT_CACERT" --resolve "$(cl "$c" fqdn):8200:$ip" \
        "https://$(cl "$c" fqdn):8200/v1/sys/seal-status" | jq -e '.sealed == false' >/dev/null 2>&1 || sealed=$((sealed + 1))
    done
    [ "$sealed" -eq 0 ] && { sleep 25; return 0; } # and the NLB's health checks to catch up
    [ $(($(now_s) - s)) -ge "$timeout" ] && return 1
    sleep 5
  done
}

# nodes <cluster> -> "<instance id> <private ip>" per running node.
nodes() {
  aws ec2 describe-instances --region "$(cl "$1" region)" \
    --filters "Name=tag:VaultCluster,Values=$(cl "$1" join_tag)" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output text
}
node_ids() { nodes "$1" | awk '{print $1}' | xargs; }
node_ips() { nodes "$1" | awk '{print $2}' | xargs; }

# ssm_run <region> <timeout_s> <command> <instance-id>... -> "<id> [Status]: <output>" per instance
ssm_run() {
  local region=$1 timeout=$2 cmd=$3 cid id st deadline
  shift 3
  [ $# -gt 0 ] || return 0
  cid=$(aws ssm send-command --region "$region" --instance-ids "$@" --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$cmd" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
    --comment "perf $PLAN" --query Command.CommandId --output text)
  deadline=$(($(now_s) + timeout + 120))
  for id in "$@"; do
    while :; do
      st=$(aws ssm get-command-invocation --region "$region" --command-id "$cid" --instance-id "$id" \
        --query Status --output text 2>/dev/null || echo Pending)
      case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
      [ "$(now_s)" -gt "$deadline" ] && { st=Timeout; break; }
      sleep 3
    done
    echo "$id [$st]: $(aws ssm get-command-invocation --region "$region" --command-id "$cid" --instance-id "$id" \
      --query StandardOutputContent --output text 2>/dev/null | tr '\n' ' ')"
  done
}

# loadgen1 <command> [timeout]: run as ubuntu with a login shell on loadgen-1
# (the West site). Base64 because AWS-RunShellScript runs /bin/sh.
loadgen1() {
  local id region b64 out
  region=$(cl pr-sec region)
  id=$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Node,Values=loadgen-1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  [ -n "$id" ] && [ "$id" != None ] || die "loadgen-1 not found in $region"
  b64=$(printf '%s' "$1" | base64 -w0)
  out=$(ssm_run "$region" "${2:-300}" "echo $b64 | base64 -d | sudo -u ubuntu bash -l" "$id")
  echo "$out"
  grep -q '\[Success\]' <<<"$out" || die "loadgen-1 command failed: $out"
}

# Grafana annotations on the default dashboard (best effort).
GRAFANA_URL=${GRAFANA_URL:-http://monitoring.$(cl primary fqdn | sed -E 's/^[^.]+\.vault\.//'):3000}
grafana_pass() {
  aws secretsmanager get-secret-value --region "$PERF_BUCKET_REGION" --secret-id "$PERF_MONITORING_SECRET" \
    --query SecretString --output text 2>/dev/null | jq -r '.grafana_admin_password // empty'
}
annotate() { # annotate <text> -> id
  local p
  p=$(grafana_pass) || return 0
  [ -n "$p" ] || return 0
  curl -s --max-time 10 -u "admin:$p" -H 'Content-Type: application/json' -X POST "$GRAFANA_URL/api/annotations" \
    -d "$(jq -n --arg t "$1" --argjson ms "$(date +%s%3N)" '{time: $ms, text: $t, tags: ["perf", "repl"]}')" |
    jq -r '.id // empty' 2>/dev/null || true
}
annotate_end() {
  [ -n "${1:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 -u "admin:$(grafana_pass)" -H 'Content-Type: application/json' \
    -X PATCH "$GRAFANA_URL/api/annotations/$1" -d "{\"timeEnd\": $(date +%s%3N)}" || true
}

upload_results() {
  aws s3 cp --recursive --only-show-errors --region "$PERF_BUCKET_REGION" "$RES" "s3://$PERF_BUCKET/results/$(basename "$RES")/"
  log "results: $RES -> s3://$PERF_BUCKET/results/$(basename "$RES")/"
}

to_secs() {
  case "$1" in
  0 | "") echo 0 ;;
  *s) echo "${1%s}" ;;
  *m) echo $((${1%m} * 60)) ;;
  *h) echo $((${1%h} * 3600)) ;;
  *) echo "$1" ;;
  esac
}
