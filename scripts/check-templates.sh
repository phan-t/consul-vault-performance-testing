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
# Values have realistic lengths (ARNs, URLs, the Consul connect config): EC2
# checks the rendered size, and one-letter placeholders once hid vault-0's
# user_data being over 16 KB. Rendered like terraform/*.tf: whole-line
# comments removed (local.user_data_comments).
ARN="arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:cvperf/vault/config-AbCdEf"
cat > "$W/main.tf" <<TF
locals {
  b = { common = file("$T/common.sh"), name = "cvperf", region = "ap-southeast-2", arch = "amd64",
        node_exporter_url = "https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-amd64.tar.gz",
        scanner_pattern = "", scanner_active_cpu = 5 }
  arn  = "$ARN"
  # Stand-ins at least as long as the real connect config (~600 bytes of JSON)
  # and Prometheus config (yamlencode in monitoring.tf).
  pad700  = join("", [for i in range(70) : "xxxxxxxxxx"])
  pad3000 = join("", [for i in range(300) : "xxxxxxxxxx"])
  re   = "/(?m)^[ \\\\t]*#(?:[^!\\\\n][^\\\\n]*)?\\\\n/"
}
output "vault"   { value = replace(templatefile("$T/vault.sh.tftpl", merge(local.b, { node_name = "vault-0", voter = true, permanent_non_voter = false, redundancy_zone = "zone-0", start_vault = true, bootstrap = true, vault_version = "2.1.1+ent", vault_fqdn = "vault.perf.internal", join_tag = "cvperf-vault", kms_key_id = "0a1b2c3d-4e5f-6789-abcd-ef0123456789", config_secret_id = local.arn, init_secret_id = local.arn, bootstrap_param = "/cvperf/vault/bootstrap-status", audit_enabled = true, consul_role_arn = "arn:aws:iam::123456789012:role/cvperf-consul", mesh_pki_path = "pki_mesh_int", mesh_ca_secret_id = local.arn, inter_pki_path = "connect_dc1_inter" })), local.re, "") }
output "vaultnv" { value = replace(templatefile("$T/vault.sh.tftpl", merge(local.b, { node_name = "vault-nv-0", voter = false, permanent_non_voter = true, redundancy_zone = "", start_vault = false, bootstrap = false, vault_version = "", vault_fqdn = "vault.perf.internal", join_tag = "cvperf-vault", kms_key_id = "0a1b2c3d-4e5f-6789-abcd-ef0123456789", config_secret_id = local.arn, init_secret_id = local.arn, bootstrap_param = "/cvperf/vault/bootstrap-status", audit_enabled = false, consul_role_arn = "arn:aws:iam::123456789012:role/cvperf-consul", mesh_pki_path = "pki_mesh_int", mesh_ca_secret_id = local.arn, inter_pki_path = "connect_dc1_inter" })), local.re, "") }
output "consul"  { value = replace(templatefile("$T/consul-server.sh.tftpl", merge(local.b, { node_name = "consul-0", voter = true, voter_count = 5, bootstrap = true, datacenter = "dc1", consul_version = "2.0.1+ent", join_tag = "cvperf-consul", server_secret_id = local.arn, bootstrap_param = "/cvperf/consul/bootstrap-status", connect_json = local.pad700, rpc_handshake_timeout = "" })), local.re, "") }
output "loadgen" { value = replace(templatefile("$T/loadgen.sh.tftpl", merge(local.b, { node_name = "loadgen-0", datacenter = "dc1", consul_version = "2.0.1+ent", vault_version = "2.1.1+ent", vault_benchmark_version = "0.3.0", k6_version = "2.3.0", vault_fqdn = "vault.perf.internal", join_tag = "cvperf-consul", client_secret_id = local.arn, vault_init_secret_id = local.arn, bucket = "cvperf-perf-0123456789abcdef", login_user = "ubuntu" })), local.re, "") }
output "monitoring" { value = replace(templatefile("$T/monitoring.sh.tftpl", merge(local.b, { monitoring_secret_id = local.arn, bucket = "cvperf-perf-0123456789abcdef", prometheus_yml = local.pad3000, prometheus_image = "p", grafana_image = "g", renderer_image = "r" })), local.re, "") }
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
