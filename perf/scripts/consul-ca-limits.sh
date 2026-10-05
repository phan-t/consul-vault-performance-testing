#!/bin/bash
# Show or change Consul Connect CA settings at runtime (no CA rotation).
#   consul-ca-limits.sh                    # show current CA config
#   consul-ca-limits.sh 200                # CSRMaxPerSecond=200 (enforced on the leader, which signs every CSR)
#   consul-ca-limits.sh 0 64               # no rate limit, max 64 concurrent signs
#   consul-ca-limits.sh 0 0                # no limits at all
#   consul-ca-limits.sh --leaf-ttl 1h      # shorter leafs => more renewals (min 1h);
#                                          # applies to newly signed leafs only
#   consul-ca-limits.sh 0 0 --leaf-ttl 1h  # combine
. /opt/perf/scripts/lib.sh
export CONSUL_HTTP_TOKEN="$CONSUL_OPERATOR_TOKEN"

RATE="" CONC="" TTL=""
while [ $# -gt 0 ]; do
  case "$1" in
  --leaf-ttl) TTL=$2; shift 2 ;;
  *) if [ -z "$RATE" ]; then RATE=$1; else CONC=$1; fi; shift ;;
  esac
done

consul connect ca get-config > /tmp/ca-config.json
if [ -z "$RATE" ] && [ -z "$TTL" ]; then
  jq '{Provider, Config: (.Config | del(.Token))}' /tmp/ca-config.json
  rm -f /tmp/ca-config.json
  exit 0
fi

jq --arg r "$RATE" --arg c "${CONC:-0}" --arg ttl "$TTL" '
  {Provider, Config: (.Config
    | if $r != "" then del(.csr_max_per_second, .csr_max_concurrent)
        | .CSRMaxPerSecond = ($r | tonumber) | .CSRMaxConcurrent = ($c | tonumber) else . end
    | if $ttl != "" then del(.leaf_cert_ttl) | .LeafCertTTL = $ttl else . end)}' \
  /tmp/ca-config.json > /tmp/ca-config-new.json
consul connect ca set-config -config-file /tmp/ca-config-new.json
rm -f /tmp/ca-config.json /tmp/ca-config-new.json
consul connect ca get-config | jq -c '{CSRMaxPerSecond: (.Config.CSRMaxPerSecond // .Config.csr_max_per_second), CSRMaxConcurrent: (.Config.CSRMaxConcurrent // .Config.csr_max_concurrent), LeafCertTTL: (.Config.LeafCertTTL // .Config.leaf_cert_ttl)}'
