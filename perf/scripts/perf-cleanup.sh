#!/bin/bash
# Deregister perf services from THIS agent (e.g. a fleet left by
# consul-register-burst.js CLEANUP=false).
#   perf-cleanup.sh                 # everything starting with perf-
#   perf-cleanup.sh perf-burst-2026 # a specific run
# Leafs already cached on the agent are dropped when their service goes; the
# agent's cache for direct leaf requests (consul-leaf.js) is only cleared by
# restarting it: sudo systemctl restart consul
. /opt/perf/scripts/lib.sh

PREFIX=${1:-perf-}
case "$PREFIX" in perf-*) ;; *) echo "prefix must start with perf-" >&2; exit 1 ;; esac
H="X-Consul-Token: $CONSUL_HTTP_TOKEN"

IDS=$(curl -s -H "$H" "$CONSUL_HTTP_ADDR/v1/agent/services" |
  jq -r --arg p "$PREFIX" 'keys[] | select(startswith($p))' |
  awk '{print (/-sidecar-proxy$/ ? 0 : 1), $0}' | sort -n | cut -d' ' -f2-)
N=0
for id in $IDS; do
  curl -s -o /dev/null -H "$H" -X PUT "$CONSUL_HTTP_ADDR/v1/agent/service/deregister/$id"
  N=$((N + 1))
done
echo "deregistered $N services matching '$PREFIX' on $PERF_NODE"
