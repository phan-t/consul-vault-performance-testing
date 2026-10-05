output "workspace" {
  value = "${var.tfc_organization}/${tfe_workspace.this.name}"
}

output "workspace_id" {
  value = tfe_workspace.this.id
}

output "next_steps" {
  value = <<-EOT
    1. Push AWS credentials to workspace ${tfe_workspace.this.name} (on the workspace or a variable set).
    2. export TF_CLOUD_ORGANIZATION=${var.tfc_organization}
    3. cd ../terraform && terraform init && terraform plan
  EOT
}
