# Vault Enterprise: var.vault_voter_count voters + var.vault_non_voter_count
# extra nodes (performance standbys): redundancy zone spares, or permanent
# non-voters without var.vault_redundancy_zones. Individual instances (not an
# ASG) keep node IDs stable; add nodes by raising the count.

resource "aws_instance" "vault" {
  for_each = { for n in local.vault_nodes : n.name => n }

  ami                    = local.ami_id
  instance_type          = var.vault_instance_type
  subnet_id              = aws_subnet.private[each.value.index % length(aws_subnet.private)].id
  iam_instance_profile   = aws_iam_instance_profile.node["vault"].name
  vpc_security_group_ids = [aws_security_group.vault.id, aws_security_group.common.id]
  monitoring             = var.detailed_monitoring

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = local.root_size
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_type           = "gp3"
    volume_size           = var.vault_data_volume.size
    iops                  = var.vault_data_volume.iops
    throughput            = var.vault_data_volume.throughput
    encrypted             = true
    delete_on_termination = true
  }

  user_data = replace(templatefile("${path.module}/templates/vault.sh.tftpl", {
    common              = file("${path.module}/templates/common.sh")
    name                = var.name
    node_name           = each.key
    voter               = each.value.voter
    permanent_non_voter = !each.value.voter && !var.vault_redundancy_zones # zone spares join as ordinary nodes
    redundancy_zone     = var.vault_redundancy_zones ? "zone-${each.value.index % var.vault_voter_count}" : ""
    start_vault         = each.value.voter || var.vault_non_voters_start
    bootstrap           = each.value.index == 0
    region              = var.aws_region
    vault_version       = var.vault_version
    vault_fqdn          = local.vault_fqdn
    join_tag            = local.vault_join_tag
    kms_key_id          = aws_kms_key.vault_unseal.key_id
    config_secret_id    = aws_secretsmanager_secret.vault_config.arn
    init_secret_id      = aws_secretsmanager_secret.vault_init.arn
    bootstrap_param     = aws_ssm_parameter.vault_bootstrap.name
    audit_enabled       = var.vault_audit_enabled
    consul_role_arn     = aws_iam_role.node["consul"].arn
    mesh_pki_path       = local.mesh_pki_path
    mesh_ca_secret_id   = aws_secretsmanager_secret.mesh_ca.arn
    inter_pki_path      = local.connect_inter_pki_path
    node_exporter_url   = local.node_exporter_url
    scanner_pattern     = var.scanner_pattern
    scanner_active_cpu  = var.scanner_active_cpu
    arch                = local.arch
  }), local.user_data_comments, "")

  tags = {
    Name         = "${var.name}-${each.key}"
    Role         = "vault"
    Node         = each.key
    Voter        = tostring(each.value.voter)
    VaultCluster = local.vault_join_tag
  }

  # Nodes are cattle only by explicit choice: use `terraform apply -replace`.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  # Secrets must exist before the node boots and reads them.
  depends_on = [
    aws_secretsmanager_secret_version.vault_config,
    aws_secretsmanager_secret_version.mesh_ca,
    aws_iam_role_policy.vault,
    aws_iam_role_policy.describe_instances,
    aws_nat_gateway.this,
    aws_route_table_association.private,
  ]
}

# --- Internal NLB: all unsealed nodes (active, standbys, non-voters) -------
# Performance standbys (incl. non-voters) serve reads, and PKI sign/issue on a
# no_store role, locally - so direct Vault clients scale horizontally here.
# Caveat for the Consul path: all ConnectCA.Sign RPCs are forwarded to the
# Consul leader, whose Vault client reuses pooled (HTTP/2) connections, so
# Consul-driven signing tends to land on one Vault node at a time.

resource "aws_lb" "vault" {
  name                             = "${var.name}-vault"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = aws_subnet.private[*].id
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "vault" {
  name                 = "${var.name}-vault"
  port                 = 8200
  protocol             = "TCP"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    protocol            = "HTTPS"
    port                = "8200"
    path                = "/v1/sys/health?standbyok=true&perfstandbyok=true"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "vault" {
  load_balancer_arn = aws_lb.vault.arn
  port              = 8200
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
}

resource "aws_lb_target_group_attachment" "vault" {
  for_each         = aws_instance.vault
  target_group_arn = aws_lb_target_group.vault.arn
  target_id        = each.value.id
  port             = 8200
}
