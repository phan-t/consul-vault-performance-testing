# Bootstrap PKI for the *transport* TLS of Vault and Consul servers.
# Service-mesh leaf certificates are NOT issued from here - Consul's Connect CA
# uses Vault's PKI secrets engine (see templates/consul-server.sh.tftpl).

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365
  early_renewal_hours   = 24 * 30

  subject {
    common_name  = "${var.name} perf-test CA"
    organization = var.name
  }

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

# --- Vault ---------------------------------------------------------------

resource "tls_private_key" "vault" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "vault" {
  private_key_pem = tls_private_key.vault.private_key_pem

  subject {
    common_name  = local.vault_fqdn
    organization = var.name
  }

  dns_names    = [local.vault_fqdn, "*.${local.vault_fqdn}", "localhost"]
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "vault" {
  cert_request_pem      = tls_cert_request.vault.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 24 * 180
  early_renewal_hours   = 24 * 14

  allowed_uses = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

# --- Consul servers ------------------------------------------------------

resource "tls_private_key" "consul_server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "consul_server" {
  private_key_pem = tls_private_key.consul_server.private_key_pem

  subject {
    common_name  = "server.${var.consul_datacenter}.consul"
    organization = var.name
  }

  # server.<dc>.consul is required by verify_server_hostname.
  dns_names = [
    "server.${var.consul_datacenter}.consul",
    local.consul_fqdn,
    "*.${local.consul_fqdn}",
    "localhost",
  ]
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "consul_server" {
  cert_request_pem      = tls_cert_request.consul_server.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 24 * 180
  early_renewal_hours   = 24 * 14

  allowed_uses = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

# --- Service mesh PKI (external root) ----------------------------------------
# Models an enterprise PKI: an offline root CA signs a Vault-held intermediate,
# which Consul uses as its (Vault-managed) root_pki_path. Consul then creates
# and rotates its own signing intermediate beneath it. Terraform plays the
# offline CA here: the root key lives only in TFC state and never reaches an
# instance. (In production the Vault intermediate key would be generated in
# Vault and its CSR signed in an offline ceremony.)

resource "tls_private_key" "mesh_root" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "mesh_root" {
  private_key_pem       = tls_private_key.mesh_root.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365 * 10

  subject {
    common_name  = "${var.name} Offline Mesh Root CA"
    organization = var.name
  }

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

resource "tls_private_key" "mesh_int" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "mesh_int" {
  private_key_pem = tls_private_key.mesh_int.private_key_pem

  subject {
    common_name  = "${var.name} Vault Mesh Intermediate CA"
    organization = var.name
  }
}

resource "tls_locally_signed_cert" "mesh_int" {
  cert_request_pem      = tls_cert_request.mesh_int.cert_request_pem
  ca_private_key_pem    = tls_private_key.mesh_root.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.mesh_root.cert_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365 * 5

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

# The NEXT mesh intermediate, for T13 (CA rotation under load): signed by the
# same offline root, so rotating Consul's root_pki_path to it changes Consul's
# active root (every leaf is re-issued) while the trust anchor stays the same.
# Like rotating the Vault intermediate before it expires. Only the load
# generators read it, when T13 mounts it; nothing uses it otherwise.
resource "tls_private_key" "mesh_int_next" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "mesh_int_next" {
  private_key_pem = tls_private_key.mesh_int_next.private_key_pem

  subject {
    common_name  = "${var.name} Vault Mesh Intermediate CA (next)"
    organization = var.name
  }
}

resource "tls_locally_signed_cert" "mesh_int_next" {
  cert_request_pem      = tls_cert_request.mesh_int_next.cert_request_pem
  ca_private_key_pem    = tls_private_key.mesh_root.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.mesh_root.cert_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365 * 5

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}
