#!/bin/bash
# Steady client load for T17 against this load generator's cluster. Each load
# runs as its own systemd unit (perf-k6-<name>) until stopped, so it outlives
# the SSM command that started it on loadgen-1.
#
#   load.sh start    start every load for this node's cluster (PERF_LOCAL_CLUSTER)
#   load.sh stop     stop them (k6 stops gracefully and writes its summary)
#   load.sh start-missing    start any load that isn't running (a rerun)
#   load.sh pause|resume kv|all   pause or resume the KV writes, or every load (k6 REST API)
#   load.sh status
#
# On the primary (loadgen-0): signing 350/s, KV writes over DAY_KEYS keys at
# KV_RATE (every write logged), AppRole logins and token renewals. On the PR
# secondary (loadgen-1): signing 350/s, logins, renewals, and a few KV writes
# (SEC_KV_RATE), which the PR secondary forwards to the primary and which
# should fail during a PR cut.
#
# k6's pass/fail thresholds are switched off (MAX_ERROR_RATE=1, MIN_ACHIEVED=0):
# during the cuts some operations are expected to fail, and that's the result,
# not a reason to stop the load.
. /opt/perf/scripts/repl/lib.sh

C=$PERF_LOCAL_CLUSTER
K6=/opt/perf/k6
LOAD_DIR="$RES/load-$PERF_NODE"
mkdir -p "$LOAD_DIR"
SIGN_RATE=${SIGN_RATE:-350}
KV_RATE=${KV_RATE:-20}
DAY_KEYS=${DAY_KEYS:-50000}
SEC_KV_RATE=${SEC_KV_RATE:-2}
LOGIN_RATE=${LOGIN_RATE:-2}
RENEW_RATE=${RENEW_RATE:-5}
LOAD_HOLD=${LOAD_HOLD:-24h}

# name:script:rate:api port
loads() {
  echo "sign:vault-sign-consul-mount.js:$SIGN_RATE:6565"
  if [ "$C" = primary ]; then echo "kv:vault-kv-write.js:$KV_RATE:6566"; else echo "kv:vault-kv-write.js:$SEC_KV_RATE:6566"; fi
  echo "login:vault-approle-login.js:$LOGIN_RATE:6567"
  echo "renew:vault-token-renew.js:$RENEW_RATE:6568"
}

start_one() {
  local name=$1 script=$2 rate=$3 port=$4 out="$LOAD_DIR/$1" approle load_token envs
  mkdir -p "$out"
  approle="$STATE_DIR/approle-consul-sim.json"
  load_token=$(cat "$STATE_DIR/load-token-$C")
  envs=(-e RATE="$rate" -e RAMP=1m -e HOLD="$LOAD_HOLD" -e MAX_ERROR_RATE=1 -e MIN_ACHIEVED=0 -e P99_MS=600000
    -e VAULT_ADDR="$(cl "$C" addr)" -e PERF_NODE="$PERF_NODE" -e SUMMARY_FILE="$out/summary.json"
    -e REQ_TIMEOUT=10s -e MAX_VUS=3000)
  case "$name" in
  sign)
    [ -s "$LOAD_DIR/leaf.csr" ] || openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$LOAD_DIR/leaf.key" -out "$LOAD_DIR/leaf.csr" -subj "/CN=perf-repl" \
      -addext "subjectAltName=URI:spiffe://perf.consul/ns/default/dc/dc1/svc/perf-repl" 2>/dev/null
    envs+=(-e PKI_PATH=pki_perf -e ROLE=leaf-nostore -e PKI_TOKEN="$load_token" -e CSR_FILE="$LOAD_DIR/leaf.csr")
    ;;
  kv)
    if [ "$C" = primary ]; then
      envs+=(-e VAULT_TOKEN="$load_token" -e KEYS="$DAY_KEYS" -e KEY_PREFIX=day -e LOG_WRITES=1)
    else
      envs+=(-e VAULT_TOKEN="$load_token" -e KEYS=1000 -e KEY_PREFIX=sec -e LOG_WRITES=1)
    fi
    ;;
  login | renew)
    envs+=(-e ROLE_ID="$(jq -r .role_id "$approle")" -e SECRET_ID="$(jq -r .secret_id "$approle")")
    ;;
  esac
  [ "$rate" -gt 0 ] 2>/dev/null || { log "load: $name rate 0; not started"; return 0; }
  sudo systemctl reset-failed "perf-k6-$name" 2>/dev/null || true
  sudo systemd-run --unit "perf-k6-$name" --uid "$(id -u)" --gid "$(id -g)" --working-directory "$out" \
    --setenv=HOME="$HOME" -p KillSignal=SIGINT -p TimeoutStopSec=120 \
    /usr/local/bin/k6 run --address "localhost:$port" --no-color --quiet \
    --log-output="file=$out/k6.log" --log-format=raw \
    --tag node="$PERF_NODE" --tag cluster="$C" "${envs[@]}" "$K6/$script" >/dev/null
  event load_start node "$PERF_NODE" cluster "$C" load "$name" rate "$rate"
  log "load: started $name at $rate/s against $C"
}

case "${1:-}" in
start)
  for l in $(loads); do IFS=: read -r n s r p <<<"$l"; start_one "$n" "$s" "$r" "$p"; done
  ;;
stop)
  for l in $(loads); do
    n=${l%%:*}
    sudo systemctl stop "perf-k6-$n" 2>/dev/null || true
    event load_stop node "$PERF_NODE" load "$n"
  done
  log "load: stopped"
  ;;
pause | resume)
  for l in $(loads); do
    IFS=: read -r n s r p <<<"$l"
    if [ "${2:-kv}" = all ] || [ "$n" = "${2:-kv}" ]; then
      systemctl is-active --quiet "perf-k6-$n" || continue
      k6 "$1" --address "localhost:$p" >/dev/null && event "load_$1" node "$PERF_NODE" load "$n"
    fi
  done
  ;;
start-missing)
  for l in $(loads); do
    IFS=: read -r n s r p <<<"$l"
    systemctl is-active --quiet "perf-k6-$n" || start_one "$n" "$s" "$r" "$p"
  done
  ;;
status)
  for l in $(loads); do n=${l%%:*}; echo "perf-k6-$n: $(systemctl is-active "perf-k6-$n" 2>/dev/null || true)"; done
  ;;
*)
  echo "usage: load.sh start|start-missing|stop|pause kv|all|resume kv|all|status" >&2
  exit 1
  ;;
esac
