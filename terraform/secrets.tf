# Instance bootstrap material lives in Secrets Manager / SSM, never in user_data.
# Everything here is also in TFC state (encrypted at rest by HCP Terraform).

resource "aws_kms_key" "vault_unseal" {
  description             = "${var.name} Vault auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

resource "random_id" "consul_gossip" {
  byte_length = 32
}

# Consul ACL tokens are pre-generated so every node can be configured at boot.
# consul-0 creates the matching tokens once the cluster has a leader.
resource "random_uuid" "consul_token" {
  for_each = toset([
    "management_secret",
    "agent_accessor", "agent_secret",
    "perf_accessor", "perf_secret",
    "metrics_accessor", "metrics_secret",
  ])
}

# Shared secret between Grafana and its image renderer (Grafana refuses the default).
resource "random_password" "renderer_token" {
  length  = 32
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

locals {
  consul_tokens = { for k, v in random_uuid.consul_token : k => v.result }
}

# --- Vault -----------------------------------------------------------------

resource "aws_secretsmanager_secret" "vault_config" {
  name                    = "${var.name}/vault/config"
  description             = "Vault license and TLS material"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "vault_config" {
  secret_id = aws_secretsmanager_secret.vault_config.id
  secret_string = jsonencode({
    license = var.vault_license
    ca      = tls_self_signed_cert.ca.cert_pem
    cert    = tls_locally_signed_cert.vault.cert_pem
    key     = tls_private_key.vault.private_key_pem
  })
}

# Mesh intermediate CA bundle for Vault to import (key + intermediate + root
# cert). The offline root's key is deliberately NOT included.
resource "aws_secretsmanager_secret" "mesh_ca" {
  name                    = "${var.name}/vault/mesh-ca"
  description             = "Mesh intermediate CA bundle (signed by the offline root) for Vault import"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "mesh_ca" {
  secret_id = aws_secretsmanager_secret.mesh_ca.id
  secret_string = jsonencode({
    pem_bundle = join("", [
      tls_private_key.mesh_int.private_key_pem,
      tls_locally_signed_cert.mesh_int.cert_pem,
      tls_self_signed_cert.mesh_root.cert_pem,
    ])
  })
}

# The next mesh intermediate bundle, for T13 (CA rotation; see tls.tf). Read by
# the load generators, which mount it in Vault when T13 runs.
resource "aws_secretsmanager_secret" "mesh_ca_next" {
  name                    = "${var.name}/vault/mesh-ca-next"
  description             = "Next mesh intermediate CA bundle (signed by the offline root), for the CA rotation test"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "mesh_ca_next" {
  secret_id = aws_secretsmanager_secret.mesh_ca_next.id
  secret_string = jsonencode({
    pem_bundle = join("", [
      tls_private_key.mesh_int_next.private_key_pem,
      tls_locally_signed_cert.mesh_int_next.cert_pem,
      tls_self_signed_cert.mesh_root.cert_pem,
    ])
  })
}

# Written by vault-0 after `vault operator init` (root token + recovery key).
# Test environment only: operators and load generators read the root token.
resource "aws_secretsmanager_secret" "vault_init" {
  name                    = "${var.name}/vault/init"
  description             = "Vault init output (root token, recovery keys). Written by vault-0."
  recovery_window_in_days = 0
}

# vault-0 flips this to "complete" once Vault is initialised and configured
# for Consul. Consul servers wait for it before starting.
resource "aws_ssm_parameter" "vault_bootstrap" {
  name  = "/${var.name}/vault/bootstrap-status"
  type  = "String"
  value = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

# --- Consul ----------------------------------------------------------------

resource "aws_secretsmanager_secret" "consul_server" {
  name                    = "${var.name}/consul/server"
  description             = "Consul server bootstrap material"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "consul_server" {
  secret_id = aws_secretsmanager_secret.consul_server.id
  secret_string = jsonencode({
    license    = var.consul_license
    gossip_key = random_id.consul_gossip.b64_std
    ca         = tls_self_signed_cert.ca.cert_pem
    cert       = tls_locally_signed_cert.consul_server.cert_pem
    key        = tls_private_key.consul_server.private_key_pem
    tokens     = local.consul_tokens
  })
}

resource "aws_secretsmanager_secret" "consul_client" {
  name                    = "${var.name}/consul/client"
  description             = "Consul client agent bootstrap material + perf test token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "consul_client" {
  secret_id = aws_secretsmanager_secret.consul_client.id
  secret_string = jsonencode({
    license     = var.consul_license
    gossip_key  = random_id.consul_gossip.b64_std
    ca          = tls_self_signed_cert.ca.cert_pem
    agent_token = local.consul_tokens["agent_secret"]
    perf_token  = local.consul_tokens["perf_secret"]
    # Test environment only: lets perf/scripts/consul-ca-limits.sh change the
    # Connect CA rate limits at runtime (`consul connect ca set-config`).
    operator_token = local.consul_tokens["management_secret"]
  })
}

# --- Monitoring ------------------------------------------------------------

resource "aws_secretsmanager_secret" "monitoring" {
  name                    = "${var.name}/monitoring"
  description             = "Grafana admin password and Consul metrics token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "monitoring" {
  secret_id = aws_secretsmanager_secret.monitoring.id
  secret_string = jsonencode({
    ca                     = tls_self_signed_cert.ca.cert_pem
    grafana_admin_password = random_password.grafana_admin.result
    renderer_token         = random_password.renderer_token.result
    consul_metrics_token   = local.consul_tokens["metrics_secret"]
  })
}
