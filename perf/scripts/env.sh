# Source me:  . /opt/perf/scripts/env.sh
# Exports tokens and endpoints for the perf tools. Test environment only.
_vault_init=$(aws secretsmanager get-secret-value --secret-id "$PERF_VAULT_INIT_SECRET" --query SecretString --output text)
_consul=$(aws secretsmanager get-secret-value --secret-id "$PERF_CONSUL_CLIENT_SECRET" --query SecretString --output text)

export VAULT_TOKEN=$(echo "$_vault_init" | jq -r .root_token)
export CONSUL_HTTP_TOKEN=$(echo "$_consul" | jq -r .perf_token)
export CONSUL_OPERATOR_TOKEN=$(echo "$_consul" | jq -r .operator_token)
unset _vault_init _consul

# Monitoring node (Grafana, Prometheus remote-write receiver). Same private
# domain as Vault, e.g. vault.perf.internal -> monitoring.perf.internal.
_domain=$(echo "$VAULT_ADDR" | sed -E 's#^https?://vault\.([^:/]+).*#\1#')
export GRAFANA_URL=${GRAFANA_URL:-http://monitoring.$_domain:3000}
export PROM_RW_URL=${PROM_RW_URL:-http://monitoring.$_domain:9090/api/v1/write}
export GRAFANA_USER=admin
export GRAFANA_PASS=$(aws secretsmanager get-secret-value --secret-id "$PERF_NAME/monitoring" --query SecretString --output text 2>/dev/null | jq -r '.grafana_admin_password // empty')
unset _domain

# Token with Consul's own Vault policy (consul-connect-ca), for tests that sign
# on Consul's intermediate directly, so Vault evaluates the same policy it does
# for Consul (root would skip policy evaluation). Periodic and reused: created
# once, then renewed if still valid.
_sign_token_file=/opt/perf/.sign-token
if [ -s "$_sign_token_file" ] && VAULT_TOKEN=$(cat "$_sign_token_file") vault token renew >/dev/null 2>&1; then
  export SIGN_VAULT_TOKEN=$(cat "$_sign_token_file")
elif SIGN_VAULT_TOKEN=$(vault token create -orphan -policy=consul-connect-ca -period=24h \
  -display-name=perf-sign -field=token 2>/dev/null); then
  export SIGN_VAULT_TOKEN
  (umask 077 && echo "$SIGN_VAULT_TOKEN" > "$_sign_token_file")
else
  export SIGN_VAULT_TOKEN=$VAULT_TOKEN
  echo "env.sh: could not create a consul-connect-ca token; using root for signing tests" >&2
fi
unset _sign_token_file

export RESULTS_DIR=/opt/perf/results
mkdir -p "$RESULTS_DIR"
