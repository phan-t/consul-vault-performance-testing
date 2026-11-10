output "regions" {
  value = var.regions
}

output "clusters" {
  description = "Each cluster: region, role, API and cluster addresses, nodes."
  value = { for k, v in local.clusters : k => {
    region       = var.regions[v.region]
    role         = v.role
    addr         = local.vault[k].addr
    cluster_addr = local.vault[k].cluster_addr
    init_secret  = local.vault[k].init_secret_name
    nodes        = local.vault[k].instances
  } }
}

output "loadgens" {
  description = "Load generators: instance ID and region."
  value = {
    "loadgen-0" = { id = aws_instance.loadgen_east.id, region = var.regions.east, cluster = "primary" }
    "loadgen-1" = { id = aws_instance.loadgen_west.id, region = var.regions.west, cluster = "pr-sec" }
  }
}

output "monitoring_instance_id" {
  value = aws_instance.monitoring.id
}

output "perf_bucket" {
  value = aws_s3_bucket.perf.id
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "access" {
  description = "Handy commands (run locally with your AWS profile)."
  value       = <<-EOT
    # Shell on loadgen-0 (East; runs the campaign)
    aws ssm start-session --region ${var.regions.east} --target ${aws_instance.loadgen_east.id}

    # Grafana on http://localhost:3000 (admin / terraform output -raw grafana_admin_password)
    aws ssm start-session --region ${var.regions.east} --target ${aws_instance.monitoring.id} \
      --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000
  EOT
}
