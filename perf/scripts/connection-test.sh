#!/bin/bash
# T3c - is a single pooled HTTP/2 connection a bottleneck for Vault signing?
#
# Drives Vault's <intermediate>/sign/leaf-cert with vault-sign-load (the same
# Vault API client stack Consul's CA provider uses) at rising concurrency, in
# two modes:
#   single  one shared client -> requests multiplexed over one connection,
#           like the Consul leader (-conns 0)
#   multi   MULTI_CONNS independent clients -> separate connections spread
#           across Vault nodes by the NLB, like many direct clients
# Signs with a token carrying Consul's own policy (SIGN_VAULT_TOKEN).
#
#   connection-test.sh
#   CONCURRENCY="1 16 64 256" MULTI_CONNS=16 STEP=60s connection-test.sh
#
# MODES="multi" runs only the multi-connection sweep; with SIGN_PATH and
# SIGN_TOKEN on the synthetic pki_perf mount this is T1/T2 (Vault cluster
# capacity, load spread across every node). LABEL names it in Grafana.
#
# Timeline: BASELINE (5m idle) -> sweep (each step: STEP_WARMUP + STEP) ->
# COOLDOWN (5m idle) -> Grafana export. Each step is annotated in Grafana.
# Writes <RUN_ID>-<node>-connection-test/connection-test.json and prints a
# table comparing the two modes: if single-mode throughput plateaus well below
# multi-mode, one connection (one Vault node) is the ceiling for Consul.
. /opt/perf/scripts/lib.sh

CONCURRENCY_LIST=${CONCURRENCY:-"1 8 32 64 128 256 512"}
MULTI_CONNS=${MULTI_CONNS:-16}
STEP=${STEP:-60s}
STEP_WARMUP=${STEP_WARMUP:-15s}
SIGN_PATH=${SIGN_PATH:-connect_${CONSUL_DATACENTER}_inter/sign/leaf-cert}
MODES=${MODES:-"single multi"}
LABEL=${LABEL:-T3c connection test}
SIGN_TOKEN=${SIGN_TOKEN:-$SIGN_VAULT_TOKEN}
# Signs per Vault node come from the route metric of SIGN_PATH's mount
# (vault_route_update_<mount>__count), not lib.sh's Consul-only SIGN_METRIC.
_mount=${SIGN_PATH%%/*}
ROUTE_METRIC="vault_route_update_${_mount//[^A-Za-z0-9]/_}__count"

PROM=$(prom_url || true)
OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-connection-test"
mkdir -p "$OUT"
make_csr "$OUT"
/opt/perf/tools/vault-sign-load/build.sh

# Label Vault nodes by name (EC2 tags) so results show vault-N, not IPs.
NODES=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Node`]|[0].Value,PrivateIpAddress]' --output text |
  awk '{printf "%s%s=%s", (NR>1?",":""), $1, $2}')

cat > "$OUT/params.json" <<P
{"tool":"vault-sign-load","test":"connection-test","run_id":"$RUN_ID","node":"$PERF_NODE","concurrency":"$CONCURRENCY_LIST","multi_conns":$MULTI_CONNS,"modes":"$MODES","step":"$STEP","step_warmup":"$STEP_WARMUP","path":"$SIGN_PATH","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
echo '[]' > "$OUT/steps.json"

T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "$LABEL (run $RUN_ID)" "perf,connection-test,$RUN_ID" "$T1")

for mode in $MODES; do
  conns=0
  [ "$mode" = multi ] && conns=$MULTI_CONNS
  for c in $CONCURRENCY_LIST; do
    echo "$(date -u +%H:%M:%S) step: mode=$mode concurrency=$c"
    SID=$(annotate "${LABEL%% *} $mode c=$c" "perf,connection-test-step,$RUN_ID")
    vault-sign-load -addr "$VAULT_ADDR" -token "$SIGN_TOKEN" -cacert "$VAULT_CACERT" \
      -path "$SIGN_PATH" -csr "$OUT/leaf.csr" -ttl 168h -nodes "$NODES" \
      -conns "$conns" -concurrency "$c" -warmup "$STEP_WARMUP" -duration "$STEP" \
      -out "$OUT/step.json" || { echo "step failed: mode=$mode c=$c"; continue; }
    annotate_end "$SID"
    # Which Vault nodes served the step, from Vault's metrics (the client only
    # sees the NLB). Wait for the last scrape, then count signs per node.
    vnodes=null
    if [ -n "$PROM" ]; then
      sleep 20
      s_start=$(jq '.start_unix_ms / 1000 | floor' "$OUT/step.json")
      s_end=$(jq '.end_unix_ms / 1000 | ceil' "$OUT/step.json")
      vnodes=$(prom_query "$PROM" "sum by (instance) (increase(${ROUTE_METRIC}[$((s_end - s_start))s]))" "$s_end" |
        jq -c 'map({(.metric.instance): (.value[1] | tonumber | round)}) | add // {}' || echo null)
    fi
    jq --argjson v "${vnodes:-null}" '. + {requests_by_vault_node: $v,
        vault_nodes_serving: (if $v then [$v[] | select(. > 0)] | length else null end)}' \
      "$OUT/step.json" > "$OUT/step.tmp" && mv "$OUT/step.tmp" "$OUT/step.json"
    jq -c '{mode, concurrency, rps: (.rps | . * 10 | round / 10), p50: .latency_ms.p50, p95: .latency_ms.p95,
            p99: .latency_ms.p99, errors, distinct_connections, vault_nodes_serving}' "$OUT/step.json"
    jq --slurpfile s "$OUT/step.json" '. + $s' "$OUT/steps.json" > "$OUT/steps.tmp" && mv "$OUT/steps.tmp" "$OUT/steps.json"
  done
done
rm -f "$OUT/step.json"

T3=$(now_ms)
annotate_end "$AID" "$T3"
idle cooldown "$COOLDOWN"
T4=$(now_ms)

jq '. as $s
  | def best(m): [$s[] | select(.mode == m and .errors == 0)] | max_by(.rps)
      | if . then {concurrency, rps, p99: .latency_ms.p99, distinct_connections, vault_nodes_serving, requests_by_vault_node} else null end;
  {steps: $s, single_max: best("single-client"), multi_max: best("multi-client")}
  | .single_to_multi_ratio = (if .single_max and .multi_max.rps > 0 then (.single_max.rps / .multi_max.rps * 100 | round / 100) else null end)' \
  "$OUT/steps.json" > "$OUT/connection-test.json"
rm -f "$OUT/steps.json"

echo
jq -r '"mode\tconc\trps\tp50_ms\tp95_ms\tp99_ms\terrors\tconns\tvault nodes\tbusiest vault node",
  (.steps[] | [.mode, .concurrency, (.rps | round), (.latency_ms.p50 | . * 10 | round / 10),
    (.latency_ms.p95 | . * 10 | round / 10), (.latency_ms.p99 | . * 10 | round / 10), .errors,
    .distinct_connections, (.vault_nodes_serving // "-"),
    (if (.requests_by_vault_node // {}) == {} then "-" else
      ((.requests_by_vault_node | to_entries | max_by(.value)) as $b
       | "\($b.key) \(($b.value / ([.requests_by_vault_node[]] | add) * 1000 | round) / 10)%") end)] | @tsv),
  "",
  (if .single_max then "single-connection max: \(.single_max.rps | round)/s at concurrency \(.single_max.concurrency) (p99 \(.single_max.p99 | round) ms, \(.single_max.vault_nodes_serving // "?") Vault node(s))" else empty end),
  (if .multi_max then "multi-connection max:  \(.multi_max.rps | round)/s at concurrency \(.multi_max.concurrency) (p99 \(.multi_max.p99 | round) ms, \(.multi_max.vault_nodes_serving // "?") Vault node(s))" else empty end),
  (if .single_to_multi_ratio then "single / multi:        \(.single_to_multi_ratio)" else empty end)' "$OUT/connection-test.json" | column -t -s $'\t'

add_phase baseline "$T0" "$T1"
add_phase steady "$T1" "$T3"
add_phase cooldown "$T3" "$T4"
echo "$PHASES" | jq . > "$OUT/phases.json"
export_grafana "$OUT" "$LABEL ($RUN_ID)"
upload_results "$OUT"
