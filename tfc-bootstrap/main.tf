# One-time bootstrap for HCP Terraform (TFC):
#   * TFC project + CLI-driven workspace for ../terraform
#   * Workspace Terraform variables (region, Enterprise licenses)
#
# AWS credentials are NOT managed here. Push static credentials to the
# workspace as environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# and AWS_SESSION_TOKEN if they are temporary) with your own tooling
# (on the workspace or a variable set) after this has been applied.
#
# Run locally after `terraform login`. State for this config is local by design;
# it holds the license text if you pass license files, so keep it out of git.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.70"
    }
  }
}

provider "tfe" {
  hostname     = var.tfc_hostname
  organization = var.tfc_organization
}

resource "tfe_project" "this" {
  name = var.tfc_project_name
}

resource "tfe_workspace" "this" {
  name              = var.tfc_workspace_name
  project_id        = tfe_project.this.id
  description       = "Consul Enterprise + Vault Enterprise performance testing environment (AWS ${var.aws_region})"
  terraform_version = var.terraform_version
  # The whole repo is uploaded so ../perf assets are available to the run.
  working_directory = "terraform"
  auto_apply        = false
  tag_names         = ["consul", "vault", "perf"]
}

resource "tfe_variable" "aws_region" {
  workspace_id = tfe_workspace.this.id
  category     = "terraform"
  key          = "aws_region"
  value        = var.aws_region
}

resource "tfe_variable" "vault_license" {
  count        = var.vault_license_file == "" ? 0 : 1
  workspace_id = tfe_workspace.this.id
  category     = "terraform"
  key          = "vault_license"
  value        = trimspace(file(var.vault_license_file))
  sensitive    = true
  description  = "Vault Enterprise license"
}

resource "tfe_variable" "consul_license" {
  count        = var.consul_license_file == "" ? 0 : 1
  workspace_id = tfe_workspace.this.id
  category     = "terraform"
  key          = "consul_license"
  value        = trimspace(file(var.consul_license_file))
  sensitive    = true
  description  = "Consul Enterprise license"
}
