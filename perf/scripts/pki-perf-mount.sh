#!/bin/bash
# Synthetic PKI mount for T1/T2, shaped like Consul's Connect CA:
#   pki-perf-mount.sh create    pki_perf/ with an EC P-256 root + intermediate and
#                               two roles mirroring Consul's "leaf-cert" role:
#                               leaf-nostore (no_store=true), leaf-store (no_store=false)
#   pki-perf-mount.sh destroy   tidy stored certificates, then disable pki_perf/
#                               (STORED_TTL: how long stored certificates live,
#                               waited out first so the tidy can delete them)
# Idempotent. Uses VAULT_TOKEN (root, from env.sh).
. /opt/perf/scripts/lib.sh
MOUNT=${PKI_PERF_MOUNT:-pki_perf}
ROOT_MOUNT=${MOUNT}_root

mounted() { vault_retry vault secrets list -format=json | jq -e --arg m "$1/" 'has($m)' >/dev/null; }

case "${1:-}" in
create)
  if ! mounted "$ROOT_MOUNT"; then
    vault secrets enable -path="$ROOT_MOUNT" -max-lease-ttl=87600h pki >/dev/null
    vault write -format=json "$ROOT_MOUNT/root/generate/internal" common_name="perf root" \
      key_type=ec key_bits=256 ttl=87600h >/dev/null
  fi
  if ! mounted "$MOUNT"; then
    vault secrets enable -path="$MOUNT" -max-lease-ttl=8760h pki >/dev/null
    csr=$(vault write -format=json "$MOUNT/intermediate/generate/internal" common_name="perf intermediate" \
      key_type=ec key_bits=256 | jq -r .data.csr)
    cert=$(vault write -format=json "$ROOT_MOUNT/root/sign-intermediate" csr="$csr" format=pem_bundle ttl=8760h |
      jq -r .data.certificate)
    vault write "$MOUNT/intermediate/set-signed" certificate="$cert" >/dev/null
  fi
  for r in nostore:true store:false; do
    vault write "$MOUNT/roles/leaf-${r%%:*}" allow_any_name=true enforce_hostnames=false \
      allowed_uri_sans="spiffe://*" require_cn=false key_type=any ttl=168h max_ttl=168h no_store="${r#*:}" >/dev/null
  done
  echo "$MOUNT ready: $MOUNT/sign/leaf-nostore, $MOUNT/sign/leaf-store"
  ;;
destroy)
  # Stored certificates make a plain unmount fail: each request through the NLB
  # can be redirected to the active node's IP (which the TLS certificate doesn't
  # cover), the client drops it, and Vault aborts the unmount ("context
  # canceled") with nothing kept (plan-1: stuck 4 h 20 min, issue #10). So:
  #   1. talk to the active node directly (no redirect);
  #   2. delete stored certificates with a server-side PKI tidy, which runs on
  #      the active node whatever the client does. Tidy only deletes EXPIRED
  #      certificates, so T2 signs with a short TTL (LEAF_TTL) and this waits
  #      for it to pass first;
  #   3. unmount the near-empty mount.
  # Errors are shown. Gives up with exit 1 after CLEANUP_DEADLINE (60m); the
  # caller treats that as a warning, not a failed test.
  deadline=$(($(date +%s) + $(to_secs "${CLEANUP_DEADLINE:-60m}")))
  active=$(vault_retry vault status -format=json | jq -r '.leader_address // empty')
  [ -n "$active" ] || { echo "can't find Vault's active node" >&2; exit 1; }
  host=${VAULT_ADDR#https://}; host=${host%%:*}
  va() { VAULT_ADDR="$active" VAULT_TLS_SERVER_NAME="$host" VAULT_CLIENT_TIMEOUT=10m "$@"; }
  if mounted "$MOUNT"; then
    s=$(date +%s)
    wait_s=$(to_secs "${STORED_TTL:-0}")
    if [ "$wait_s" -gt 0 ]; then
      echo "waiting ${wait_s}s for $MOUNT's stored certificates to expire (STORED_TTL)"
      sleep "$((wait_s + 5))"
    fi
    echo "tidying $MOUNT (deletes expired stored certificates, on the active node)"
    va vault write "$MOUNT/tidy" tidy_cert_store=true tidy_revoked_certs=true safety_buffer=1s >/dev/null
    while :; do
      st=$(va vault read -format=json "$MOUNT/tidy-status" | jq -c '.data | {state, cert_store_deleted_count, error}') || st='{}'
      case "$(jq -r '.state // ""' <<<"$st")" in
      Finished) echo "tidy finished: $st"; break ;;
      Error | Cancelled) echo "tidy failed: $st" >&2; exit 1 ;;
      esac
      [ "$(date +%s)" -lt "$deadline" ] || { echo "tidy still running at the deadline: $st" >&2; exit 1; }
      sleep 15
    done
  fi
  for m in "$MOUNT" "$ROOT_MOUNT"; do
    if mounted "$m"; then
      s=$(date +%s)
      until va vault secrets disable "$m"; do
        [ "$(date +%s)" -lt "$deadline" ] || { echo "$m still mounted at the deadline" >&2; exit 1; }
        echo "retrying the unmount of $m in 30s" >&2
        sleep 30
      done
      echo "disabled $m ($(($(date +%s) - s))s)"
    fi
  done
  ;;
*)
  echo "usage: pki-perf-mount.sh create|destroy" >&2
  exit 1
  ;;
esac
