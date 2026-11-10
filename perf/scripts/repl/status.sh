#!/bin/bash
# Replication status and log shipper counters.
#
#   status.sh watch [interval_s]   every second (default) until stopped, one
#                                  line per cluster in $RES/status.jsonl:
#                                  state, WAL indexes, merkle root, connection
#   status.sh guards <cluster>     log shipper counters summed over the
#                                  cluster's nodes, as JSON: missing_guard
#                                  (the buffer no longer held what a secondary
#                                  asked for) and guard_found (it did)
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
  c=${2:?usage: status.sh guards <cluster>}
  for ip in $(node_ips "$c"); do
    curl -s --max-time 5 --cacert "$VAULT_CACERT" --resolve "$(cl "$c" fqdn):8200:$ip" \
      "https://$(cl "$c" fqdn):8200/v1/sys/metrics?format=prometheus" || true
  done | awk '/^vault_logshipper_streamWALs_(missing_guard|guard_found)[ {]/ {
      split($1, n, "{"); sub(/^vault_logshipper_streamWALs_/, "", n[1]); s[n[1]] += $NF }
    END { printf "{\"missing_guard\": %d, \"guard_found\": %d}\n", s["missing_guard"], s["guard_found"] }'
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
