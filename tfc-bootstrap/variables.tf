variable "tfc_organization" {
  description = "HCP Terraform organization name."
  type        = string
}

variable "tfc_hostname" {
  description = "HCP Terraform hostname (change for Terraform Enterprise)."
  type        = string
  default     = "app.terraform.io"
}

variable "tfc_project_name" {
  description = "HCP Terraform project to create for the workspace."
  type        = string
  default     = "consul-vault-perf"
}

variable "tfc_workspace_name" {
  description = "Workspace name. Must match the `cloud` block in ../terraform/versions.tf."
  type        = string
  default     = "consul-vault-perf"
}

variable "terraform_version" {
  description = "Terraform version for workspace runs."
  type        = string
  default     = "~> 1.15.0"
}

variable "aws_region" {
  description = "AWS region for the environment."
  type        = string
  default     = "ap-southeast-2"
}

variable "vault_license_file" {
  description = "Path to a Vault Enterprise license file. Empty = set the `vault_license` workspace variable manually."
  type        = string
  default     = ""
}

variable "consul_license_file" {
  description = "Path to a Consul Enterprise license file. Empty = set the `consul_license` workspace variable manually."
  type        = string
  default     = ""
}
