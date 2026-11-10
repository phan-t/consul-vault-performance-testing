#!/bin/bash
# The operations in Table 6, tried one at a time, and the checks around them.
# Every result is one JSON line in $RES/probes.jsonl:
#   {ts, label, cluster, op, code, ok, expect, body}
# "expect" is what Table 6 (or the HLD's OPS-B paragraph) says should happen
# for that label; ok is whether the call succeeded (2xx).
#
#   checks.sh probe <cluster> <label> <expect: all|reads>
#       KV read, leaf signing, AppRole login, token renewal, KV write, PKI role
#       change, CA configuration change. expect=reads: the reads, signing,
#       login and renewal should succeed and the writes fail (a PR secondary
#       during a PR cut); expect=all: everything should succeed.
#   checks.sh revoke-setup          two stored leafs on the primary (control, cut)
#   checks.sh revoke <cluster> <control|cut> <label> <expect: ok|fail>
#   checks.sh revoke-confirm <control|cut>   wait until the primary shows it revoked
#   checks.sh opsb-setup            log in once with consul-sim and limited-use
#                                   on the PR secondary, so their entities exist
#   checks.sh opsb <label> [fail|ok] the three OPS-B logins on the PR secondary;
#                                   the last two should fail during a PR cut
#   checks.sh marker-write | marker-read <label>   stale data, shown directly
. /opt/perf/scripts/repl/lib.sh

PROBES="$RES/probes.jsonl"

record() { # record <label> <cluster> <op> <expect ok|fail> <"code body">
  local code=${5%% *} body=${5#* }
  jq -cn --arg ts "$(now)" --arg label "$1" --arg cluster "$2" --arg op "$3" --arg expect "$4" \
    --arg code "$code" --arg body "$body" \
    '{ts: $ts, label: $label, cluster: $cluster, op: $op, code: ($code | tonumber? // 0),
      ok: ($code | test("^2")), expect: $expect, body: ($body | .[0:300])}
     | .as_expected = ((.ok and .expect == "ok") or ((.ok | not) and .expect == "fail"))' >> "$PROBES"
  log "probe $1 $2 $3: ${code} (expect $4)"
}

csr() {
  local d="$STATE_DIR/probe-csr"
  [ -s "$d.csr" ] || openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$d.key" -out "$d.csr" -subj "/CN=probe" -addext "subjectAltName=URI:spiffe://perf.consul/svc/probe" 2>/dev/null
  jq -Rs . "$d.csr"
}

approle() { jq -c '{role_id, secret_id}' "$STATE_DIR/approle-$1.json"; }

probe() {
  local c=$1 label=$2 expect=$3 w r tok res
  w=fail
  [ "$expect" = all ] && w=ok
  record "$label" "$c" kv_read ok "$(api "$c" GET kv_perf/data/probe)"
  record "$label" "$c" leaf_sign ok "$(api "$c" POST pki_perf/sign/leaf-nostore "{\"csr\": $(csr), \"ttl\": \"1h\"}")"
  res=$(TOKEN_OVERRIDE=none api "$c" POST auth/approle/login "$(approle consul-sim)")
  record "$label" "$c" approle_login ok "$res"
  tok=$(jq -r '.auth.client_token // empty' <<<"${res#* }" 2>/dev/null || true)
  if [ -n "$tok" ]; then
    record "$label" "$c" token_renew ok "$(TOKEN_OVERRIDE=$tok api "$c" POST auth/token/renew-self '{"increment": "1h"}')"
    TOKEN_OVERRIDE=$tok api "$c" POST auth/token/revoke-self >/dev/null
  else
    record "$label" "$c" token_renew ok "000 no token from the login"
  fi
  record "$label" "$c" kv_write "$w" "$(api "$c" POST "kv_perf/data/probe-$c" "{\"data\": {\"label\": \"$label\"}}")"
  record "$label" "$c" pki_role_change "$w" "$(api "$c" POST pki_perf/roles/probe-role '{"allow_any_name": true, "ttl": "1h", "no_store": true}')"
  record "$label" "$c" ca_config_change "$w" "$(api "$c" POST pki_perf/intermediate/generate/internal '{"common_name": "probe", "key_type": "ec", "key_bits": 256}')"
}

case "${1:-}" in
probe)
  probe "${2:?cluster}" "${3:?label}" "${4:?expect all|reads}"
  ;;
revoke-setup)
  for n in control cut; do
    [ -s "$STATE_DIR/revoke-$n" ] && continue
    serial=$(v primary write -format=json pki_perf/issue/leaf-store common_name="revoke-$n" ttl=24h | jq -er .data.serial_number)
    [ -n "$serial" ] || die "revoke-setup: no serial for $n"
    echo "$serial" > "$STATE_DIR/revoke-$n.tmp" && mv "$STATE_DIR/revoke-$n.tmp" "$STATE_DIR/revoke-$n"
    event revoke_setup leaf "$n" serial "$(cat "$STATE_DIR/revoke-$n")"
  done
  ;;
revoke)
  c=${2:?cluster}
  n=${3:?control|cut}
  record "${4:?label}" "$c" "cross_cluster_revoke_$n" "${5:?ok|fail}" \
    "$(api "$c" POST pki_perf/revoke "{\"serial_number\": \"$(cat "$STATE_DIR/revoke-$n")\"}")"
  ;;
revoke-confirm)
  n=${2:?control|cut}
  s=$(now_s)
  until [ "$(v primary read -format=json "pki_perf/cert/$(cat "$STATE_DIR/revoke-$n")" | jq -r '.data.revocation_time // 0')" != "0" ]; do
    if [ $(($(now_s) - s)) -gt 900 ]; then
      event revoke_confirm leaf "$n" revoked false secs "$(($(now_s) - s))"
      log "revoke-confirm $n: not revoked on the primary after 15 min"
      exit 1
    fi
    sleep 10
  done
  event revoke_confirm leaf "$n" revoked true secs "$(($(now_s) - s))"
  ;;
opsb-setup)
  for r in consul-sim limited-use; do
    res=$(TOKEN_OVERRIDE=none api pr-sec POST auth/approle/login "$(approle "$r")")
    record opsb-setup pr-sec "login_$r" ok "$res"
  done
  ;;
opsb)
  label=${2:?label}
  w=${3:-fail} # the two logins that need the primary: fail during a PR cut, ok with the link up
  record "$label" pr-sec opsb_existing_entity_unlimited ok "$(TOKEN_OVERRIDE=none api pr-sec POST auth/approle/login "$(approle consul-sim)")"
  record "$label" pr-sec opsb_first_login_new_entity "$w" "$(TOKEN_OVERRIDE=none api pr-sec POST auth/approle/login "$(approle first-login)")"
  record "$label" pr-sec opsb_limited_use_secret_id "$w" "$(TOKEN_OVERRIDE=none api pr-sec POST auth/approle/login "$(approle limited-use)")"
  ;;
marker-write)
  val="$(now)"
  v primary kv put -mount=kv_perf marker value="$val" >/dev/null
  event marker_write value "$val"
  ;;
marker-read)
  res=$(api pr-sec GET kv_perf/data/marker)
  event marker_read label "${2:?label}" primary "$(v primary kv get -mount=kv_perf -field=value marker 2>/dev/null || echo "?")" \
    pr_sec "$(jq -r '.data.data.value // "?"' <<<"${res#* }" 2>/dev/null || echo "?")"
  ;;
*)
  sed -n '2,24p' "$0" >&2
  exit 1
  ;;
esac
