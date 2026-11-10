output "instances" {
  description = "Nodes by name: id, private_ip, availability_zone, tags."
  value = { for k, v in aws_instance.this : k => {
    id                = v.id
    private_ip        = v.private_ip
    availability_zone = v.availability_zone
    voter             = v.tags["Voter"]
  } }
}

output "fqdn" {
  value = var.fqdn
}

output "addr" {
  description = "API through the NLB."
  value       = "https://${var.fqdn}:8200"
}

output "cluster_addr" {
  description = "Cluster port through the NLB (empty unless cluster_port_nlb)."
  value       = var.cluster_port_nlb ? "https://${var.fqdn}:8201" : ""
}

output "join_tag" {
  description = "VaultCluster tag value on every node."
  value       = local.join_tag
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "init_secret_arn" {
  value = aws_secretsmanager_secret.init.arn
}

output "init_secret_name" {
  value = aws_secretsmanager_secret.init.name
}

output "bootstrap_param_name" {
  value = aws_ssm_parameter.bootstrap.name
}

output "bootstrap_param_arn" {
  value = aws_ssm_parameter.bootstrap.arn
}

output "nlb_target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "iam_role_arn" {
  value = aws_iam_role.vault.arn
}

output "tls_cert_pem" {
  value = tls_locally_signed_cert.this.cert_pem
}

output "tls_private_key_pem" {
  value     = tls_private_key.this.private_key_pem
  sensitive = true
}
