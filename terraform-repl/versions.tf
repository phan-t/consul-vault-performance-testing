terraform {
  required_version = ">= 1.9.0"

  # Organization comes from TF_CLOUD_ORGANIZATION. The workspace is created by
  # ../tfc-bootstrap (repl_workspace_name). Its own state: the main build in
  # ../terraform is unaffected.
  cloud {
    workspaces {
      name = "consul-vault-perf-repl"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials come from the TFC workspace environment variables, as for the
# main build. The East site holds the PR primary and the PR secondary's DR
# replica; the West site holds the PR secondary and the primary's DR replica.
# Each site is its own VPC; by default both are in Sydney (variables.tf).
provider "aws" {
  alias  = "east"
  region = var.regions.east

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "west"
  region = var.regions.west

  default_tags {
    tags = local.default_tags
  }
}
