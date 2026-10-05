#!/usr/bin/env bash
# Collect the public URLs and admin/root credentials for Grafana, Vault and
# Consul into a local, git-ignored file (default: ./credentials.txt, mode 0600).
#
#   export TF_CLOUD_ORGANIZATION=<org>
#   ./scripts/get-credentials.sh [output-file]
#
# Sources:
#   * URLs, Grafana password, Consul tokens -> `terraform output` (TFC state)
#   * Vault root token -> Secrets Manager directly if your AWS session may read
#     it, otherwise via SSM Run Command on a load generator (whose instance role
#     can). Note: SSM keeps command output in its history for ~30 days.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF_DIR="$ROOT/terraform"
OUT=${1:-"$ROOT/credentials.txt"}

for bin in terraform jq aws; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done
if [ -z "${TF_CLOUD_ORGANIZATION:-}" ]; then
  echo "set TF_CLOUD_ORGANIZATION (e.g. export TF_CLOUD_ORGANIZATION=my-org)" >&2
  exit 1
fi

echo "reading terraform outputs..." >&2
TF=$(terraform -chdir="$TF_DIR" output -json)
out() { echo "$TF" | jq -r --arg k "$1" '.[$k].value // empty'; }
or_none() { if [ -n "$1" ]; then echo "$1"; else echo "(not exposed)"; fi; }

REGION=$(out region)
VAULT_INIT_SECRET=$(echo "$TF" | jq -r '.secrets.value.vault_init')
LOADGEN_ID=$(echo "$TF" | jq -r '.loadgen_instance_ids.value[0] // empty')

# --- Vault root token --------------------------------------------------------
VAULT_TOKEN=""
if VAULT_TOKEN=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$VAULT_INIT_SECRET" \
  --query SecretString --output text 2>/dev/null | jq -r .root_token) && [ -n "$VAULT_TOKEN" ] && [ "$VAULT_TOKEN" != "null" ]; then
  VAULT_SOURCE="Secrets Manager"
elif [ -n "$LOADGEN_ID" ]; then
  echo "Secrets Manager not readable from this session; fetching Vault root token via SSM on $LOADGEN_ID..." >&2
  PARAMS=$(jq -n --arg s "$VAULT_INIT_SECRET" --arg r "$REGION" \
    '{commands: ["aws secretsmanager get-secret-value --region \($r) --secret-id \($s) --query SecretString --output text | jq -r .root_token"]}')
  CID=$(aws ssm send-command --region "$REGION" --instance-ids "$LOADGEN_ID" \
    --document-name AWS-RunShellScript --comment "get-credentials: vault root token" \
    --parameters "$PARAMS" --query Command.CommandId --output text)
  aws ssm wait command-executed --region "$REGION" --command-id "$CID" --instance-id "$LOADGEN_ID" 2>/dev/null || true
  VAULT_TOKEN=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$LOADGEN_ID" \
    --query StandardOutputContent --output text | tr -d '[:space:]')
  VAULT_SOURCE="SSM Run Command on $LOADGEN_ID"
fi
if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
  VAULT_TOKEN="(unavailable - is Vault initialised?)"
  VAULT_SOURCE="-"
fi

# --- Write file ----------------------------------------------------------------
umask 077
cat > "$OUT" <<EOF
# Consul + Vault perf environment credentials
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/get-credentials.sh
# SENSITIVE - git-ignored and excluded from TFC uploads. Do not share.

== Grafana ===================================================================
URL:       $(or_none "$(out grafana_url)")
Username:  admin
Password:  $(out grafana_admin_password)

== Vault =====================================================================
UI:        $(or_none "$(out vault_ui_url)")
Internal:  $(out vault_addr)
Login:     method "Token"
Root token: $VAULT_TOKEN
           (source: $VAULT_SOURCE)

== Consul ====================================================================
UI:        $(or_none "$(out consul_ui_url)")
Internal:  $(out consul_https_addr)
Login:     "Log in" -> ACL token
Management token (full access): $(out consul_management_token)
Perf token (read-mostly):       $(out consul_perf_token)
EOF
chmod 600 "$OUT"
echo "wrote $OUT" >&2
