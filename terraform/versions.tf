terraform {
  required_version = ">= 1.9.0"

  # Organization comes from TF_CLOUD_ORGANIZATION. The workspace is created by
  # ../tfc-bootstrap; keep the name in sync with var.tfc_workspace_name there.
  cloud {
    workspaces {
      name = "consul-vault-perf"
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

# Credentials come from the TFC workspace environment variables
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.name
      Environment = "perf-test"
      ManagedBy   = "terraform"
    }
  }
}
