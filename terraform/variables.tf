# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for every resource. Also used as the EC2 `Project` tag for auto-join and Prometheus discovery."
  type        = string
  default     = "cvperf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name))
    error_message = "Use 2-21 lowercase alphanumerics/dashes, starting with a letter."
  }
}

variable "aws_region" {
  description = "AWS region. Sydney by default."
  type        = string
  default     = "ap-southeast-2"
}

variable "availability_zones" {
  description = "AZs to spread nodes across. Voters are placed round-robin, so 5 voters over 3 AZs = 2/2/1."
  type        = list(string)
  default     = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "single_nat_gateway" {
  description = "One NAT gateway (cheaper) vs one per AZ. Only used for package downloads and AWS APIs."
  type        = bool
  default     = true
}

variable "private_domain" {
  description = "Route53 private hosted zone for the environment."
  type        = string
  default     = "perf.internal"
}

variable "root_volume_size" {
  description = "Root volume size (GB) for Vault, Consul and load generator nodes."
  type        = number
  default     = 50
}

variable "detailed_monitoring" {
  description = "EC2 detailed (1-minute) CloudWatch monitoring. Prometheus covers the hosts either way."
  type        = bool
  default     = true
}

variable "ami_arch" {
  description = <<-EOT
    Architecture of the Ubuntu 24.04 image to use: "amd64" or "arm64".
    Instance types must match (e.g. m7i/c7i/t3a for amd64,
    m7g/c7g/t4g for arm64).
  EOT
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.ami_arch)
    error_message = "ami_arch must be amd64 or arm64."
  }
}

variable "ami_owner" {
  description = "AWS account that publishes the base image. Default: Canonical (public Ubuntu images)."
  type        = string
  default     = "099720109477"
}

variable "ami_name_pattern" {
  description = "AMI name filter, with %s replaced by ami_arch (amd64 / arm64). Must be Ubuntu 24.04 (the bootstrap uses apt and systemd)."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-%s-server-*"
}

# ---------------------------------------------------------------------------
# Licenses (set as sensitive TFC workspace variables)
# ---------------------------------------------------------------------------

variable "vault_license" {
  description = "Vault Enterprise license string."
  type        = string
  sensitive   = true
}

variable "consul_license" {
  description = "Consul Enterprise license string (IBM license required for Consul 2.x)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Vault
# ---------------------------------------------------------------------------

variable "vault_version" {
  description = "vault-enterprise RPM version, e.g. \"2.1.1+ent\". Empty = latest in the HashiCorp repo."
  type        = string
  default     = "2.1.1+ent"
}

variable "vault_voter_count" {
  description = "Vault Raft voters."
  type        = number
  default     = 5

  validation {
    condition     = contains([3, 5, 7], var.vault_voter_count)
    error_message = "Use an odd voter count: 3, 5 or 7."
  }
}

variable "vault_non_voter_count" {
  description = "Vault Enterprise permanent non-voters (retry_join_as_non_voter). They act as performance standbys."
  type        = number
  default     = 0
}

variable "vault_non_voters_start" {
  description = <<-EOT
    Start Vault on non-voter nodes at boot. false = provision them fully (Vault
    installed and configured) but leave Vault stopped, so they don't join the
    cluster or take NLB traffic until started - run-plan.sh starts them over
    SSM for T9-V, so the campaign needs no mid-run terraform apply.
  EOT
  type        = bool
  default     = true
}

variable "vault_instance_type" {
  type    = string
  default = "m7i.2xlarge"
}

variable "vault_data_volume" {
  description = "Raft data volume (gp3)."
  type = object({
    size       = number
    iops       = number
    throughput = number
  })
  default = { size = 100, iops = 6000, throughput = 250 }
}

variable "vault_audit_enabled" {
  description = "Enable a file audit device. Realistic, but adds disk I/O per request."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Consul
# ---------------------------------------------------------------------------

variable "consul_version" {
  description = <<-EOT
    consul-enterprise RPM version. Empty = latest in the HashiCorp repo.
    Pinned to 2.0.1+ent: 2.0.2-2.0.4 release binaries drop Raft/Serf/memberlist
    metrics (hashicorp/consul#23812), and 2.0.4 also closes idle RPC streams
    causing EOF errors (hashicorp/consul#23923).
  EOT
  type        = string
  default     = "2.0.1+ent"
}

variable "consul_datacenter" {
  type    = string
  default = "dc1"
}

variable "consul_rpc_handshake_timeout" {
  description = <<-EOT
    Server limits.rpc_handshake_timeout. Consul 2.0.4 re-arms this timeout while
    an RPC stream is idle between requests, so pooled client streams are closed
    and the next call fails with EOF (hashicorp/consul#23923). Writes such as
    ConnectCA.Sign are not retried and surface as HTTP 500s. Set "60s" to work
    around that on 2.0.4. Empty = Consul default (5s); correct for 2.0.1, which
    doesn't have the bug.
  EOT
  type        = string
  default     = ""
}

variable "consul_voter_count" {
  description = "Consul server voters."
  type        = number
  default     = 5

  validation {
    condition     = contains([3, 5, 7], var.consul_voter_count)
    error_message = "Use an odd voter count: 3, 5 or 7."
  }
}

variable "consul_read_replica_count" {
  description = "Consul Enterprise read replicas (non-voting servers)."
  type        = number
  default     = 0
}

variable "consul_instance_type" {
  type    = string
  default = "m7i.2xlarge"
}

variable "consul_data_volume" {
  description = "Consul data volume (gp3)."
  type = object({
    size       = number
    iops       = number
    throughput = number
  })
  default = { size = 100, iops = 6000, throughput = 250 }
}

variable "consul_connect_ca" {
  description = <<-EOT
    Vault Connect CA provider settings. csr_max_per_second defaults to Consul's
    built-in 50/s; set 0 and use csr_max_concurrent to remove the rate cap for
    throughput tests.
  EOT
  type = object({
    leaf_cert_ttl         = string
    intermediate_cert_ttl = string
    private_key_type      = string
    private_key_bits      = number
    csr_max_per_second    = number
    csr_max_concurrent    = number
  })
  default = {
    leaf_cert_ttl         = "168h" # 7 days, as planned for production
    intermediate_cert_ttl = "8760h"
    private_key_type      = "ec"
    private_key_bits      = 256
    csr_max_per_second    = 50
    csr_max_concurrent    = 0
  }
}

# ---------------------------------------------------------------------------
# Load generators and monitoring
# ---------------------------------------------------------------------------

variable "loadgen_count" {
  description = "k6 / vault-benchmark load generator nodes (each runs a Consul client agent)."
  type        = number
  default     = 2
}

variable "loadgen_instance_type" {
  description = <<-EOT
    Load generator instance type. Memory-optimised: the Consul client agent on
    each load generator caches every leaf consul-leaf.js fetches (about 12 KB
    each), about 55 GB for one 12-minute step at 6,400/s. plan-1's c7i.4xlarge
    (32 GiB) ran out at 6,400/s. r7i.4xlarge has the same 16 vCPUs with 128 GiB.
  EOT
  type        = string
  default     = "r7i.4xlarge"
}

variable "vault_benchmark_version" {
  type    = string
  default = "0.3.0"
}

variable "k6_version" {
  type    = string
  default = "2.3.0"
}

variable "monitoring_enabled" {
  description = "Deploy a Prometheus + Grafana node."
  type        = bool
  default     = true
}

variable "monitoring_instance_type" {
  type    = string
  default = "m7i.xlarge"
}

variable "monitoring_volume_size" {
  description = "Monitoring node root volume (GB); holds 30 days of Prometheus data."
  type        = number
  default     = 200
}

variable "scanner_pattern" {
  description = "Extended regex for security/inventory agent processes on your image (matched with pgrep -f), e.g. a vulnerability scanner. Their CPU use is published as perf_scanner_cpu_percent / perf_scanner_active. Empty = none (the metric stays 0)."
  type        = string
  default     = ""
}

variable "scanner_active_cpu" {
  description = "perf_scanner_active is 1 when scanner processes use at least this % of one CPU core (they stay resident but idle between scans)."
  type        = number
  default     = 5
}

variable "node_exporter_version" {
  type    = string
  default = "1.12.1"
}

variable "prometheus_image" {
  type    = string
  default = "prom/prometheus:v3.15.0"
}

variable "renderer_image" {
  description = "Grafana image renderer (PNG exports of panels/dashboards)."
  type        = string
  default     = "grafana/grafana-image-renderer:v5.12.4"
}

variable "grafana_image" {
  type    = string
  default = "grafana/grafana:13.2.2"
}

# ---------------------------------------------------------------------------
# Optional public Grafana (ALB + ACM)
# ---------------------------------------------------------------------------

variable "grafana_public_zone" {
  description = "Public Route 53 hosted zone (in this account) for an HTTPS Grafana endpoint. Empty = no public endpoint; use SSM port forwarding."
  type        = string
  default     = ""
}

variable "grafana_public_hostname" {
  description = "Hostname label within grafana_public_zone. Empty = \"grafana-<name>\"."
  type        = string
  default     = ""
}

variable "grafana_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Grafana host (max 4; enforced per host on the ALB)."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.grafana_allowed_cidrs) <= 4
    error_message = "ALB rules allow at most 4 source CIDRs alongside the host condition."
  }
}

variable "expose_vault_ui" {
  description = "Also publish the Vault UI/API as https://vault-<name>.<grafana_public_zone> on the same ALB."
  type        = bool
  default     = false
}

variable "expose_consul_ui" {
  description = "Also publish the Consul UI/API as https://consul-<name>.<grafana_public_zone> on the same ALB."
  type        = bool
  default     = false
}

variable "ui_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Vault and Consul hosts (max 4). These are full APIs: keep this narrow."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.ui_allowed_cidrs) <= 4
    error_message = "ALB rules allow at most 4 source CIDRs alongside the host condition."
  }
}
