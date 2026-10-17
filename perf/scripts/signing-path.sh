#!/bin/bash
# T16 (issue #14): point the Consul leader's Vault CA provider at another
# signing path for a test, and back.
#   signing-path.sh up <haproxy|proxy|alb>   start the path, switch Consul's CA Address to it
#   signing-path.sh down                     switch back, stop the path
# Writes <RUN_ID>-<node>-signing-path/path.json (up and down results).
#
# Paths (README "Consul signing distribution"):
#   haproxy  https://127.0.0.1:8211 on each Consul server: HAProxy balancing each
#            HTTP/2 request across every Vault node
#   proxy    https://127.0.0.1:8210 on each Consul server: Vault Proxy to the
#            NLB with keep-alives off, so the NLB picks a node per sign
#   alb      https://alb.<vault host>: an ALB balancing each request (var.vault_alb)
# signing-path-node.sh starts them on every Consul server (any can become
# leader), over SSM. Only the CA provider's Address changes, with the same PKI
# paths, like consul-ca-limits.sh's other changes: no rotation. The guard checks
# that: Consul's active root, signing key and intermediates must be the same
# before the switch, after it and after switching back. A change is a finding
# (and, with auto_encrypt, a restarted agent would be locked out: issue #11).
#
# Exit codes: 0 ok, 3 path unavailable (skip the test), 4 the CA changed, 1 other.
. /opt/perf/scripts/lib.sh

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-signing-path"
mkdir -p "$OUT"
VAULT_HOST=$(sed -E 's#^https?://([^:/]+).*#\1#' <<<"$VAULT_ADDR")
NODE_SCRIPT=/usr/local/bin/signing-path-node.sh

ca_state() { # Consul's active root, its signing key and intermediates (hashed)
  local roots
  roots=$(curl -sf --max-time 10 -H "X-Consul-Token: $CONSUL_OPERATOR_TOKEN" "$CONSUL_HTTP_ADDR/v1/connect/ca/roots") || { echo null; return; }
  jq -c --arg ih "$(jq -r '[.Roots[] | select(.Active) | .IntermediateCerts // [] | join("")] | join("")' <<<"$roots" | sha256sum | cut -c1-16)" \
    '([.Roots[] | select(.Active)][0]) as $a | {active_root_id: .ActiveRootID, signing_key_id: $a.SigningKeyID, intermediates_sha256: $ih}' <<<"$roots"
}

ca_address() {
  CONSUL_HTTP_TOKEN=$CONSUL_OPERATOR_TOKEN consul connect ca get-config | jq -r '.Config.Address // .Config.address'
}

# on_servers <signing-path-node.sh args>: run it on every Consul server; fails unless each says result=ok.
on_servers() {
  local ids out
  ids=$(project_instances "Name=tag:Role,Values=consul")
  [ -n "$ids" ] || { echo "no Consul server instances"; return 1; }
  out=$(ssm_run 900 "aws s3 cp --only-show-errors --region $AWS_DEFAULT_REGION s3://$PERF_BUCKET/assets/perf/scripts/signing-path-node.sh $NODE_SCRIPT && chmod 0755 $NODE_SCRIPT && $NODE_SCRIPT $*" $ids)
  echo "$out" >> "$OUT/servers.log"
  if [ "$(grep -c 'result=ok' <<<"$out")" -ne "$(wc -w <<<"$ids")" ]; then
    grep -v 'result=ok' <<<"$out" | sed -E 's/.*(result=fail.*)/\1/' | head -3
    return 1
  fi
}

# leaf_ok: one leaf through the local agent, signed by the leader over the new path.
leaf_ok() {
  local i
  for i in $(seq 1 15); do
    curl -sf --max-time 20 -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$CONSUL_HTTP_ADDR/v1/agent/connect/ca/leaf/perf-t16-check-$(date +%s%N)" |
      jq -e '.CertPEM | length > 0' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

up() {
  local path=$1 addr version nodes msg before after prev ok upstream=$VAULT_ADDR
  case "$path" in
  haproxy) addr=https://127.0.0.1:8211 ;;
  proxy) addr=https://127.0.0.1:8210 ;;
  alb)
    addr=https://alb.$VAULT_HOST
    upstream=$addr # the node checks Vault through the ALB itself
    getent hosts "alb.$VAULT_HOST" >/dev/null || { echo "no alb.$VAULT_HOST: build with var.vault_alb (run-campaign.sh --with-t16)"; exit 3; }
    ;;
  *) echo "usage: signing-path.sh up <haproxy|proxy|alb>" >&2; exit 1 ;;
  esac
  version=$(vault version | awk '{print $2}' | sed 's/^v//')
  nodes=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].Tags[?Key==`Node`].Value[]' --output text | tr '\t' '\n' | sort | sed "s/\$/.$VAULT_HOST/" | tr '\n' ' ')
  prev=$(ca_address)
  before=$(ca_state)
  echo "$path: starting on every Consul server (Vault $version; nodes: $nodes)"
  # Recorded before anything changes, so down can undo a partial up.
  jq -n -c --arg p "$path" --arg a "$addr" --arg prev "$prev" --argjson b "$before" \
    '{path: $p, available: null, address: $a, previous_address: $prev, ca_before: $b}' > "$OUT/path.json"
  if ! msg=$(on_servers up "$path" "$upstream" "$version" $nodes); then
    on_servers down >/dev/null || true
    echo "$path unavailable: $msg"
    jq -n -c --arg p "$path" --arg m "$msg" '{path: $p, available: false, reason: $m}' > "$OUT/path.json"
    exit 3
  fi
  echo "$path: switching Consul's CA provider Address $prev -> $addr"
  consul-ca-limits.sh --address "$addr"
  leaf_ok && ok=true || ok=false
  after=$(ca_state)
  jq -n -c --arg p "$path" --arg a "$addr" --arg prev "$prev" --argjson ok "$ok" --argjson b "$before" --argjson af "$after" \
    '{path: $p, available: true, address: $a, previous_address: $prev, leaf_ok: $ok,
      ca_before: $b, ca_after_switch: $af, ca_unchanged_after_switch: ($b == $af)}' > "$OUT/path.json"
  if [ "$before" != "$after" ]; then
    echo "$path: Consul's CA changed on the Address switch: $before -> $after (a rotation: see issue #11)"
    exit 4
  fi
  $ok || { echo "$path: no leaf signed through $addr within 30 s"; exit 1; }
  echo "$path: leaf signed through $addr; CA unchanged ($(jq -r .active_root_id <<<"$after"))"
}

down() {
  local prev before after rc=0
  # The path may be running even without path.json (up stopped early): always stop it.
  [ -f "$OUT/path.json" ] || echo '{}' > "$OUT/path.json"
  prev=$(jq -r '.previous_address // empty' "$OUT/path.json")
  before=$(jq -c '.ca_before // null' "$OUT/path.json")
  if [ -n "$prev" ] && [ "$(ca_address)" != "$prev" ]; then
    echo "switching Consul's CA provider Address back to $prev"
    consul-ca-limits.sh --address "$prev" || rc=1
  fi
  on_servers down >/dev/null || { echo "stopping the path on some Consul server failed (see $OUT/servers.log)"; rc=1; }
  after=$(ca_state)
  jq -c --arg addr "$(ca_address)" --argjson af "$after" \
    '. + {restored_address: $addr, ca_after_restore: $af,
          ca_unchanged: (if .ca_before == null then null
                         else (.ca_before == $af and (.ca_unchanged_after_switch // true)) end)}' "$OUT/path.json" > "$OUT/path.tmp" && mv "$OUT/path.tmp" "$OUT/path.json"
  if [ "$before" != "null" ] && [ "$before" != "$after" ]; then
    echo "Consul's CA changed during the test: $before -> $after"
    rc=4
  fi
  upload_results "$OUT" >/dev/null
  return $rc
}

case "${1:-}" in
up) up "${2:-}" ;;
down) down ;;
*) echo "usage: signing-path.sh up <haproxy|proxy|alb> | down" >&2; exit 1 ;;
esac
