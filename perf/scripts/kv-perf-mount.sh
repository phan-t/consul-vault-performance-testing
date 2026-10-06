#!/bin/bash
# KV v2 mount for T11 (vault-kv-write.js).
#   kv-perf-mount.sh create    kv_perf/ (KV v2, max_versions=1, so overwrites don't grow the data)
#   kv-perf-mount.sh destroy   disable kv_perf/
# Idempotent. Uses VAULT_TOKEN (root, from env.sh).
. /opt/perf/scripts/lib.sh
MOUNT=${KV_MOUNT:-kv_perf}

mounted() { vault_retry vault secrets list -format=json | jq -e --arg m "$MOUNT/" 'has($m)' >/dev/null; }

case "${1:-}" in
create)
  mounted || vault_retry vault secrets enable -path="$MOUNT" -version=2 kv >/dev/null
  # A new KV v2 mount takes a moment before it accepts writes on every node.
  for i in $(seq 1 30); do
    vault write "$MOUNT/config" max_versions=1 >/dev/null 2>&1 &&
      vault kv put -mount="$MOUNT" probe value=1 >/dev/null 2>&1 && break
    [ "$i" -eq 30 ] && { echo "$MOUNT not writable after 60s" >&2; exit 1; }
    sleep 2
  done
  echo "$MOUNT ready (KV v2, max_versions=1)"
  ;;
destroy)
  if mounted; then
    s=$(date +%s)
    for i in $(seq 1 30); do vault secrets disable "$MOUNT" >/dev/null 2>&1 || true; mounted || break; sleep 10; done
    mounted && { echo "$MOUNT still mounted after retries" >&2; exit 1; }
    echo "disabled $MOUNT ($(($(date +%s) - s))s)"
  fi
  ;;
*)
  echo "usage: kv-perf-mount.sh create|destroy" >&2
  exit 1
  ;;
esac
