#!/bin/bash
# Synthetic PKI mount for T1/T2, shaped like Consul's Connect CA:
#   pki-perf-mount.sh create    pki_perf/ with an EC P-256 root + intermediate and
#                               two roles mirroring Consul's "leaf-cert" role:
#                               leaf-nostore (no_store=true), leaf-store (no_store=false)
#   pki-perf-mount.sh destroy   disable pki_perf/ (deletes any stored certificates)
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
  for m in "$MOUNT" "$ROOT_MOUNT"; do
    if mounted "$m"; then
      s=$(date +%s)
      # Stored certificates make this slow (T11 stores ~100k per size), so allow 30 min.
      # Retry until it's gone: just after a leader change the call can fail
      # outright (redirected to a node IP), and a slow one can time out while
      # Vault finishes the unmount.
      for i in $(seq 1 36); do
        VAULT_CLIENT_TIMEOUT=30m vault secrets disable "$m" >/dev/null 2>&1 || true
        mounted "$m" || break
        sleep 10
      done
      mounted "$m" && { echo "$m still mounted after retries" >&2; exit 1; }
      echo "disabled $m ($(($(date +%s) - s))s)"
    fi
  done
  ;;
*)
  echo "usage: pki-perf-mount.sh create|destroy" >&2
  exit 1
  ;;
esac
