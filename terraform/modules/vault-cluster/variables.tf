# One Vault Enterprise cluster: nodes, internal NLB, KMS auto-unseal, bootstrap
# secrets, TLS, security group, DNS, and the nodes' IAM role. Used once by the
# main build (../../) and four times by the replication build (../../../terraform-repl).
# The caller's default aws provider sets the region.

variable "name" {
  description = "Resource name prefix for this cluster, e.g. \"cvperf\" (main build) or \"cvrepl-primary\". Also Vault's cluster_name and the auto-join tag (\"<name>-vault\")."
  type        = string
}

variable "project" {
  description = "Project name: the EC2 Name tag prefix (\"<project>-<node>\") and the TLS certificate's organisation."
  type        = string
}

variable "node_prefix" {
  description = "Node names: <node_prefix>-N for voters, <node_prefix>-nv-N for non-voters."
  type        = string
  default     = "vault"
}

variable "region" {
  description = "Region of the caller's aws provider (auto-join, KMS, STS)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Allowed to reach the API (8200)."
  type        = string
}

variable "peer_cidrs" {
  description = "Other VPCs allowed to reach the API (8200) and cluster port (8201), e.g. the other region's VPC for replication. Empty for the main build."
  type        = list(string)
  default     = []
}

variable "subnet_ids" {
  description = "Private subnets. Nodes are placed round-robin."
  type        = list(string)
}

variable "extra_security_group_ids" {
  description = "Also attached to every node (the caller's common rules: node_exporter, egress)."
  type        = list(string)
  default     = []
}

variable "ami_id" {
  type = string
}

variable "arch" {
  type = string
}

variable "root_volume_size" {
  type = number
}

variable "instance_type" {
  type = string
}

variable "data_volume" {
  type = object({
    size       = number
    iops       = number
    throughput = number
  })
}

variable "detailed_monitoring" {
  type    = bool
  default = true
}

variable "voter_count" {
  type = number
}

variable "non_voter_count" {
  type    = number
  default = 0
}

variable "redundancy_zones" {
  type    = bool
  default = true
}

variable "non_voters_start" {
  type    = bool
  default = true
}

variable "vault_version" {
  type = string
}

variable "vault_license" {
  type      = string
  sensitive = true
}

variable "audit_enabled" {
  type    = bool
  default = true
}

variable "alb_listener" {
  description = "Second listener on 8202 for the main build's T16 ALB."
  type        = bool
  default     = false
}

variable "cluster_port_nlb" {
  description = "Also listen on 8201 on the NLB, so other clusters can use <fqdn>:8201 as primary_cluster_addr."
  type        = bool
  default     = false
}

variable "health_check_extra" {
  description = "Appended to the NLB health check query, e.g. \"&drsecondarycode=200\" so DR replicas stay in service. Empty for the main build."
  type        = string
  default     = ""
}

variable "logshipper_buffer_length" {
  description = "replication.logshipper_buffer_length. 0 = Vault's default."
  type        = number
  default     = 0
}

variable "logshipper_buffer_size" {
  description = "replication.logshipper_buffer_size, e.g. \"2gb\". Empty = Vault's default."
  type        = string
  default     = ""
}

variable "fqdn" {
  description = "API name, e.g. vault.perf.internal. Nodes are <node>.<fqdn>."
  type        = string
}

variable "zone_id" {
  description = "Private hosted zone for fqdn."
  type        = string
}

variable "ca_cert_pem" {
  type = string
}

variable "ca_private_key_pem" {
  type      = string
  sensitive = true
}

variable "consul_setup" {
  description = "Main build only: the bootstrap also sets up Consul's AWS auth role and mesh PKI mounts. null = skip."
  type = object({
    role_arn           = string
    mesh_pki_path      = string
    mesh_ca_secret_arn = string
    inter_pki_path     = string
  })
  default = null
}

variable "common_sh" {
  description = "Contents of the shared templates/common.sh helpers."
  type        = string
}

variable "user_data_comments" {
  description = "Regex of whole-line comments removed from the rendered user_data (16 KB limit)."
  type        = string
}

variable "node_exporter_url" {
  type = string
}

variable "scanner_pattern" {
  type    = string
  default = ""
}

variable "scanner_active_cpu" {
  type    = number
  default = 5
}

variable "boot_after" {
  description = "IDs the nodes must wait for (NAT gateway, route table associations). Only creates a dependency; not used on the node."
  type        = list(string)
  default     = []
}
