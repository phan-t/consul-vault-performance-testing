#!/usr/bin/env bash
# Render every user_data template with dummy values and check it:
#   * bash -n syntax
#   * every function the script calls is defined (catches lost helpers)
#   * size under the 16 KB user_data limit
# Run before any apply that changes terraform/templates/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T="$ROOT/terraform/templates"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cat > "$W/main.tf" <<TF
locals {
  b = { common = file("$T/common.sh"), name = "cvperf", region = "ap-southeast-2", node_exporter_url = "x", arch = "amd64",
        scanner_pattern = "", scanner_active_cpu = 5 }
}
output "vault"   { value = templatefile("$T/vault.sh.tftpl", merge(local.b, { node_name = "vault-0", voter = true, start_vault = true, bootstrap = true, vault_version = "2.1.1+ent", vault_fqdn = "v", join_tag = "t", kms_key_id = "k", config_secret_id = "c", init_secret_id = "i", bootstrap_param = "/p", audit_enabled = true, consul_role_arn = "arn", mesh_pki_path = "pki_mesh_int", mesh_ca_secret_id = "m", inter_pki_path = "connect_dc1_inter" })) }
output "vaultnv" { value = templatefile("$T/vault.sh.tftpl", merge(local.b, { node_name = "vault-nv-0", voter = false, start_vault = false, bootstrap = false, vault_version = "", vault_fqdn = "v", join_tag = "t", kms_key_id = "k", config_secret_id = "c", init_secret_id = "i", bootstrap_param = "/p", audit_enabled = false, consul_role_arn = "arn", mesh_pki_path = "pki_mesh_int", mesh_ca_secret_id = "m", inter_pki_path = "connect_dc1_inter" })) }
output "consul"  { value = templatefile("$T/consul-server.sh.tftpl", merge(local.b, { node_name = "consul-0", voter = true, voter_count = 5, bootstrap = true, datacenter = "dc1", consul_version = "2.0.1+ent", join_tag = "t", server_secret_id = "s", bootstrap_param = "/p", connect_json = "{}", rpc_handshake_timeout = "" })) }
output "loadgen" { value = templatefile("$T/loadgen.sh.tftpl", merge(local.b, { node_name = "loadgen-0", datacenter = "dc1", consul_version = "2.0.1+ent", vault_version = "2.1.1+ent", vault_benchmark_version = "0.3.0", k6_version = "2.3.0", vault_fqdn = "v", join_tag = "t", client_secret_id = "c", vault_init_secret_id = "i", bucket = "b", login_user = "ubuntu" })) }
output "monitoring" { value = templatefile("$T/monitoring.sh.tftpl", merge(local.b, { monitoring_secret_id = "m", bucket = "b", prometheus_yml = "a: 1", prometheus_image = "p", grafana_image = "g", renderer_image = "r" })) }
TF
(cd "$W" && terraform init -input=false >/dev/null && terraform apply -auto-approve -input=false >/dev/null)
rc=0
for o in vault vaultnv consul loadgen monitoring; do
  (cd "$W" && terraform output -raw "$o") > "$W/$o.sh"
  defined=$(grep -oE '^[a-z_]+\(\) \{' "$W/$o.sh" | sed 's/() {//' | sort -u)
  # top-level calls: lines that start with a known-helper-shaped word and aren't definitions/keywords
  # Strip heredoc bodies (config files) so their keys don't look like calls.
  awk 'h { if ($0 == h) h = ""; next } { print } match($0, /<<-?'"'"'?[A-Za-z_]+'"'"'?/) { d = substr($0, RSTART, RLENGTH); gsub(/[<\-'"'"']/, "", d); h = d }' \
    "$W/$o.sh" > "$W/$o.code"
  called=$(grep -oE '^ *(retry +)?[a-z_]+( |$)' "$W/$o.code" | sed -E 's/^ *//; s/^retry +//; s/ $//' | sort -u |
    grep -v -x -E 'if|then|else|elif|fi|for|do|done|while|until|case|esac|export|echo|cat|mkdir|chmod|chown|cp|mv|rm|systemctl|set|exec|trap|local|return|sleep|curl|jq|aws|grep|sed|awk|printf|install|tar|unzip|useradd|umask|shred|vault|consul|docker|apt-get|update-ca-certificates|sysctl|mount|blkid|mkfs|find|cd|export|ln|touch|until|read|shift|exit|test|true|false|wait|tee|gpg|consul-template|dpkg|apt-mark|getconf|seq|lsblk|findmnt|pgrep|fuser|cloud-init|hostname|date|base64|ss|mkfs\.xfs|unset|trust|break|continue|source|eval|command|type|which|node_exporter|k6|openssl|python3|pip3|go|sudo|runuser' || true)
  missing=$(comm -23 <(echo "$called") <(echo "$defined") | grep -E '^(tune_os|install_|base_packages|apt_|ensure_|get_secret|mount_|trust_ca|service_|retry|http_code|imds|[a-z]+_[a-z_]+)$' || true)
  size=$(wc -c < "$W/$o.sh" | tr -d ' ')
  if bash -n "$W/$o.sh" && [ -z "$missing" ] && [ "$size" -lt 16384 ]; then
    printf '  %-10s ok   (%s bytes, %s helpers)\n' "$o" "$size" "$(wc -w <<<"$defined" | tr -d ' ')"
  else
    printf '  %-10s FAIL (%s bytes) missing: %s\n' "$o" "$size" "$(echo $missing)"; rc=1
  fi
done
exit $rc
