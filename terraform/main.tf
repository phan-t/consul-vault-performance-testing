data "aws_caller_identity" "current" {}

# Base image: the latest Ubuntu 24.04 per arch, from ami_owner / ami_name_pattern
# (Canonical's public images by default; point them at your own hardened image).
data "aws_ami" "ubuntu" {
  for_each = toset(["amd64", "arm64"])

  filter {
    name   = "name"
    values = [format(var.ami_name_pattern, each.value)]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  most_recent = true
  owners      = [var.ami_owner]
}

locals {
  ami        = data.aws_ami.ubuntu[var.ami_arch]
  ami_id     = local.ami.id
  arch       = var.ami_arch
  login_user = "ubuntu"

  # Root volumes can't be smaller than the image's own snapshot.
  ami_root_size = one([for b in local.ami.block_device_mappings : b.ebs.volume_size if b.device_name == local.ami.root_device_name])
  root_size     = max(var.root_volume_size, local.ami_root_size)

  vault_fqdn  = "vault.${var.private_domain}"
  consul_fqdn = "consul.${var.private_domain}"

  # EC2 tags used by cloud auto-join (Vault retry_join, Consul retry_join).
  vault_join_tag  = "${var.name}-vault"
  consul_join_tag = "${var.name}-consul"

  vault_nodes = concat(
    [for i in range(var.vault_voter_count) : { name = "vault-${i}", voter = true, index = i }],
    [for i in range(var.vault_non_voter_count) : { name = "vault-nv-${i}", voter = false, index = var.vault_voter_count + i }],
  )

  consul_nodes = concat(
    [for i in range(var.consul_voter_count) : { name = "consul-${i}", voter = true, index = i }],
    [for i in range(var.consul_read_replica_count) : { name = "consul-rr-${i}", voter = false, index = var.consul_voter_count + i }],
  )

  # Mesh PKI mounts in Vault:
  #   mesh_pki_path          - Vault-managed intermediate signed by the offline
  #                            root; Consul's root_pki_path (read-only to Consul)
  #   connect_inter_pki_path - Consul's own signing intermediate
  mesh_pki_path          = "pki_mesh_int"
  connect_inter_pki_path = "connect_${var.consul_datacenter}_inter"

  node_exporter_url = "https://github.com/prometheus/node_exporter/releases/download/v${var.node_exporter_version}/node_exporter-${var.node_exporter_version}.linux-${var.ami_arch}.tar.gz"
}
