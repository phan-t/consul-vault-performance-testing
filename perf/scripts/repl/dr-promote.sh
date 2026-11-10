#!/bin/bash
# The DR cut's promotion (T17): promote the primary's DR replica while its link
# is down, count the writes it's missing, then demote it and point it back at
# the primary.
#
#   dr-promote.sh token               make the DR operation token (before the cut)
#   dr-promote.sh promote <cut_ms>     promote primary-dr, then count its missing
#                                      writes against loadgen-0's KV write log
#   dr-promote.sh reconnect            after the link is restored: demote,
#                                      revoke the old secondary ID, and
#                                      update-primary with a new token
#
# The load generators only ever talk to the primary and the PR secondary, so
# no client writes to the promoted replica: there are never two primaries
# taking writes. The DR operation token is a batch token from the dr-ops role
# on the primary, made before the cut, as the HLD's script makes them.
. /opt/perf/scripts/repl/lib.sh

DR=primary-dr
P=primary
WRITES="$RES/load-loadgen-0/kv/k6.log"

ok2xx() { local c=${1%% *}; [ "$c" -ge 200 ] 2>/dev/null && [ "$c" -lt 300 ]; }

dr_token() {
  local f="$STATE_DIR/dr-token"
  if [ ! -s "$f" ]; then
    (umask 077 && v "$P" write -format=json auth/token/create/dr-ops ttl=24h | jq -er .auth.client_token > "$f")
    event dr_token created "$(now)"
  fi
  cat "$f"
}

promote() {
  local cut_ms=$1 tok t0 res secs
  tok=$(dr_token)
  t0=$(date +%s%3N)
  event dr_promote_start cluster "$DR"
  res=$(TOKEN_OVERRIDE=none api "$DR" POST sys/replication/dr/secondary/promote "{\"dr_operation_token\": \"$tok\"}")
  log "promote $DR: $res"
  ok2xx "$res" || die "promote failed: $res"
  # It's a DR primary once its active node serves requests again.
  secs=0
  until [ "$(repl_status "$DR" | jq -r '.dr.mode // ""')" = "primary" ] && wait_healthy "$DR" 5; do
    sleep 1
    secs=$((secs + 1))
    [ "$secs" -gt 600 ] && die "$DR not a DR primary 10 min after promote"
  done
  event dr_promote_done cluster "$DR" secs "$((($(date +%s%3N) - t0) / 1000))"
  # The primary's root token works on the promoted cluster: DR replicates tokens.
  token "$P" >/dev/null
  cp "$STATE_DIR/token-$P" "$STATE_DIR/token-$DR"
  python3 /opt/perf/scripts/repl/verify.py writes-missing "$DR" "$WRITES" "$cut_ms" "$t0" "$P"
}

reconnect() {
  local tok wrap t0
  tok=$(dr_token)
  t0=$(now_s)
  event dr_reconnect_start cluster "$DR"
  v "$DR" write -f sys/replication/dr/primary/demote >/dev/null || die "demote failed"
  forget_token "$DR"
  sleep 10
  v "$P" write sys/replication/dr/primary/revoke-secondary id="$DR" >/dev/null || true
  wrap=$(v "$P" write -format=json sys/replication/dr/primary/secondary-token id="$DR-$(date +%s)" ttl=30m | jq -er .wrap_info.token)
  res=$(TOKEN_OVERRIDE=none api "$DR" POST sys/replication/dr/secondary/update-primary \
    "$(jq -cn --arg d "$tok" --arg t "$wrap" --arg a "$(cl "$P" addr)" '{dr_operation_token: $d, token: $t, primary_api_addr: $a, ca_file: "/opt/vault/tls/ca.crt"}')")
  log "update-primary $DR: $res"
  ok2xx "$res" || die "update-primary failed: $res"
  secs=$(wait_caught_up "$DR" dr "$P" 3600) || die "$DR not caught up 60 min after update-primary"
  event dr_reconnect_done cluster "$DR" secs "$(($(now_s) - t0))"
}

case "${1:-}" in
token) dr_token >/dev/null ;;
promote) promote "${2:?cut_ms}" ;;
reconnect) reconnect ;;
*) sed -n '2,15p' "$0" >&2; exit 1 ;;
esac
