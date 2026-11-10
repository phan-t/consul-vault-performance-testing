# Replication build for T17 (issue #23): four Vault Enterprise clusters in two
# sites, no Consul. Defaults are the full-size run; the dry run
# (run-repl.sh --dry-run) writes dryrun.auto.tfvars with 3 voters.

variable "name" {
  description = "Name prefix for every resource, and the EC2 Project tag."
  type        = string
  default     = "cvrepl"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.name))
    error_message = "Use 2-11 lowercase alphanumerics/dashes, starting with a letter (NLB names are limited to 32 characters)."
  }
}

variable "regions" {
  description = "Region of each site. Both Sydney by default: Melbourne (ap-southeast-4) isn't allowed on the account, so the West site is a second VPC in Sydney, with latency added between the sites (repl/latency.sh)."
  type        = object({ east = string, west = string })
  default = {
    east = "ap-southeast-2"
    west = "ap-southeast-2"
  }
}

variable "availability_zones" {
  type = object({ east = list(string), west = list(string) })
  default = {
    east = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
    west = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
  }
}

variable "vpc_cidrs" {
  description = "Must not overlap: the VPCs are peered. repl/latency.sh delays traffic to the other site's CIDR."
  type        = object({ east = string, west = string })
  default = {
    east = "10.60.0.0/16"
    west = "10.61.0.0/16"
  }
}

variable "private_domain" {
  description = "Private hosted zone, associated with both VPCs. Clusters are <cluster>.vault.<domain>."
  type        = string
  default     = "repl.internal"
}

variable "root_volume_size" {
  type    = number
  default = 50
}

variable "detailed_monitoring" {
  type    = bool
  default = true
}

variable "ami_arch" {
  type    = string
  default = "amd64"
}

variable "ami_owner" {
  type    = string
  default = "099720109477"
}

variable "ami_name_pattern" {
  type    = string
  default = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-%s-server-*"
}

variable "vault_license" {
  description = "Vault Enterprise licence string. Must include Performance and DR replication."
  type        = string
  sensitive   = true
}

variable "vault_version" {
  type    = string
  default = "2.1.1+ent"
}

variable "vault_voter_count" {
  description = "Voters on every cluster (no non-voters). 5 for the run, 3 for the dry run."
  type        = number
  default     = 5

  validation {
    condition     = contains([3, 5, 7], var.vault_voter_count)
    error_message = "Use an odd voter count: 3, 5 or 7."
  }
}

variable "vault_instance_type" {
  type    = string
  default = "m7i.2xlarge"
}

variable "vault_data_volume" {
  type = object({
    size       = number
    iops       = number
    throughput = number
  })
  default = { size = 100, iops = 6000, throughput = 250 }
}

variable "vault_audit_enabled" {
  type    = bool
  default = true
}

variable "logshipper_buffer_length" {
  description = "replication.logshipper_buffer_length on every cluster. 0 = Vault's default (16384)."
  type        = number
  default     = 0
}

variable "logshipper_buffer_size" {
  description = "replication.logshipper_buffer_size on every cluster. Empty = Vault's default (10% of memory)."
  type        = string
  default     = ""
}

variable "loadgen_instance_type" {
  type    = string
  default = "r7i.4xlarge"
}

variable "k6_version" {
  type    = string
  default = "2.3.0"
}

variable "monitoring_instance_type" {
  type    = string
  default = "m7i.xlarge"
}

variable "monitoring_volume_size" {
  type    = number
  default = 200
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
  type    = string
  default = "grafana/grafana-image-renderer:v5.12.4"
}

variable "grafana_image" {
  type    = string
  default = "grafana/grafana:13.2.2"
}

variable "scanner_pattern" {
  type    = string
  default = ""
}

variable "scanner_active_cpu" {
  type    = number
  default = 5
}
