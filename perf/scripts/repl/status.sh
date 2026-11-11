#!/bin/bash
# Replication status and log shipper counters.
#
#   status.sh watch [interval_s]   every second (default) until stopped, one
#                                  line per cluster in $RES/status.jsonl:
#                                  state, WAL indexes, merkle root, connection
#   status.sh guards <cluster> <since_ms>
#                                  how much the log shipper counters rose on
#                                  the cluster's nodes since since_ms, from
#                                  Prometheus, as JSON: missing_guard (the
#                                  buffer no longer held what a secondary asked
#                                  for), guard_found (it did), buffer_over_run.
#                                  Vault keeps its own metrics for only 30 s.
#   status.sh show                 every cluster's state, for people
. /opt/perf/scripts/repl/lib.sh

summary() { # summary <cluster> -> one compact JSON line
  repl_status "$1" | jq -c --arg ts "$(now)" --arg c "$1" '{ts: $ts, cluster: $c} + (
    [["dr", .dr], ["performance", .performance]] | map(select(.[1] != null) | {
      (.[0]): (.[1] | {mode, state, connection_state, last_wal, last_remote_wal, last_dr_wal,
        last_performance_wal, last_reindex_epoch, merkle_root,
        secondaries: ([.secondaries[]? | {node_id, connection_status, last_heartbeat}])})
    }) | add // {})'
}

case "${1:-}" in
watch)
  interval=${2:-1}
  log "status: watching every ${interval}s -> $RES/status.jsonl"
  while :; do
    for c in $CLUSTERS; do summary "$c" >> "$RES/status.jsonl" 2>/dev/null & done
    wait
    sleep "$interval"
  done
  ;;
guards)
  c=${2:?usage: status.sh guards <cluster> <since_ms>}
  since=${3:?usage: status.sh guards <cluster> <since_ms>}
  win=$(( ($(date +%s%3N) - since) / 1000 + 20 ))
  prom="http://monitoring.$(cl primary fqdn | sed -E 's/^[^.]+\.vault\.//'):9090"
  out="{}"
  for m in missing_guard guard_found buffer_over_run; do
    v=$(curl -sG --max-time 10 "$prom/api/v1/query" \
      --data-urlencode "query=sum(increase(vault_logshipper_streamWALs_${m}{job=\"vault-$c\"}[${win}s]))" |
      jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "?")
    out=$(jq -c --arg k "$m" --arg v "$v" '. + {($k): (($v | tonumber? // 0) | round)}' <<<"$out")
  done
  echo "$out"
  ;;
show)
  for c in $CLUSTERS; do
    summary "$c" | jq -r '"\(.cluster): " + ([to_entries[] | select(.key == "dr" or .key == "performance") |
      "\(.key) \(.value.mode) \(.value.state // "-") last_wal=\(.value.last_wal // "-") last_remote_wal=\(.value.last_remote_wal // "-")"] | join("; "))'
  done
  ;;
*)
  echo "usage: status.sh watch [interval_s] | guards <cluster> | show" >&2
  exit 1
  ;;
esac
