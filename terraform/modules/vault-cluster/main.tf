terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}

locals {
  join_tag = "${var.name}-vault"

  nodes = concat(
    [for i in range(var.voter_count) : { name = "${var.node_prefix}-${i}", voter = true, index = i }],
    [for i in range(var.non_voter_count) : { name = "${var.node_prefix}-nv-${i}", voter = false, index = var.voter_count + i }],
  )
}

# --- Nodes -------------------------------------------------------------------
# Individual instances (not an ASG) keep node IDs stable; add nodes by raising
# the count. Non-voters are redundancy zone spares, or permanent non-voters
# without var.redundancy_zones; either way they're performance standbys.

resource "aws_instance" "this" {
  for_each = { for n in local.nodes : n.name => n }

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[each.value.index % length(var.subnet_ids)]
  iam_instance_profile   = aws_iam_instance_profile.vault.name
  vpc_security_group_ids = concat([aws_security_group.this.id], var.extra_security_group_ids)
  monitoring             = var.detailed_monitoring

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_type           = "gp3"
    volume_size           = var.data_volume.size
    iops                  = var.data_volume.iops
    throughput            = var.data_volume.throughput
    encrypted             = true
    delete_on_termination = true
  }

  user_data = replace(templatefile("${path.module}/templates/vault.sh.tftpl", {
    common                   = var.common_sh
    name                     = var.name
    node_name                = each.key
    voter                    = each.value.voter
    permanent_non_voter      = !each.value.voter && !var.redundancy_zones # zone spares join as ordinary nodes
    redundancy_zone          = var.redundancy_zones ? "zone-${each.value.index % var.voter_count}" : ""
    start_vault              = each.value.voter || var.non_voters_start
    bootstrap                = each.value.index == 0
    region                   = var.region
    vault_version            = var.vault_version
    vault_fqdn               = var.fqdn
    join_tag                 = local.join_tag
    kms_key_id               = aws_kms_key.unseal.key_id
    config_secret_id         = aws_secretsmanager_secret.config.arn
    init_secret_id           = aws_secretsmanager_secret.init.arn
    bootstrap_param          = aws_ssm_parameter.bootstrap.name
    audit_enabled            = var.audit_enabled
    alb_listener             = var.alb_listener
    consul_setup             = var.consul_setup != null
    consul_role_arn          = try(var.consul_setup.role_arn, "")
    mesh_pki_path            = try(var.consul_setup.mesh_pki_path, "")
    mesh_ca_secret_id        = try(var.consul_setup.mesh_ca_secret_arn, "")
    inter_pki_path           = try(var.consul_setup.inter_pki_path, "")
    logshipper_buffer_length = var.logshipper_buffer_length
    logshipper_buffer_size   = var.logshipper_buffer_size
    node_exporter_url        = var.node_exporter_url
    scanner_pattern          = var.scanner_pattern
    scanner_active_cpu       = var.scanner_active_cpu
    arch                     = var.arch
    # Not used by the template: makes the nodes wait for var.boot_after.
    boot_after = join(",", var.boot_after)
  }), var.user_data_comments, "")

  tags = {
    Name         = "${var.project}-${each.key}"
    Role         = "vault"
    Node         = each.key
    Voter        = tostring(each.value.voter)
    VaultCluster = local.join_tag
  }

  # Nodes are cattle only by explicit choice: use `terraform apply -replace`.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  # Secrets must exist before the node boots and reads them.
  depends_on = [
    aws_secretsmanager_secret_version.config,
    aws_iam_role_policy.vault,
    aws_iam_role_policy.describe_instances,
  ]
}

# --- Internal NLB: all unsealed nodes (active, standbys, non-voters) -------
# Performance standbys (incl. non-voters) serve reads, and PKI sign/issue on a
# no_store role, locally - so direct Vault clients scale horizontally here.
# Caveat for the Consul path: all ConnectCA.Sign RPCs are forwarded to the
# Consul leader, whose Vault client reuses pooled (HTTP/2) connections, so
# Consul-driven signing tends to land on one Vault node at a time.

resource "aws_lb" "this" {
  name                             = "${var.name}-vault"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "this" {
  name                 = "${var.name}-vault"
  port                 = 8200
  protocol             = "TCP"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    protocol            = "HTTPS"
    port                = "8200"
    path                = "/v1/sys/health?standbyok=true&perfstandbyok=true${var.health_check_extra}"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8200
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_target_group_attachment" "this" {
  for_each         = aws_instance.this
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = each.value.id
  port             = 8200
}

# Replication (var.cluster_port_nlb): <fqdn>:8201 for primary_cluster_addr.
# Only the active node serves replication on the cluster port: a standby has
# no TLS config for the replication ALPN and fails the handshake ("tls:
# internal error", seen in the repl-dry run). So the health check passes on the
# active node only: standbys answer 429, performance standbys 473, and a DR
# secondary's active node 200 (drsecondarycode). The NLB keeps the client's
# IP, so a cut by source IP (cut.sh) also covers connections through it.
resource "aws_lb_target_group" "cluster" {
  count                = var.cluster_port_nlb ? 1 : 0
  name                 = "${var.name}-vcl"
  port                 = 8201
  protocol             = "TCP"
  vpc_id               = var.vpc_id
  deregistration_delay = 10

  health_check {
    protocol            = "HTTPS"
    port                = "8200"
    path                = "/v1/sys/health?drsecondarycode=200"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "cluster" {
  count             = var.cluster_port_nlb ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 8201
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cluster[0].arn
  }
}

resource "aws_lb_target_group_attachment" "cluster" {
  for_each         = var.cluster_port_nlb ? aws_instance.this : {}
  target_group_arn = aws_lb_target_group.cluster[0].arn
  target_id        = each.value.id
  port             = 8201
}

# --- Auto-unseal, bootstrap secrets ----------------------------------------
# Instance bootstrap material lives in Secrets Manager / SSM, never in user_data.

resource "aws_kms_key" "unseal" {
  description             = "${var.name} Vault auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "unseal" {
  name          = "alias/${var.name}-vault-unseal"
  target_key_id = aws_kms_key.unseal.key_id
}

resource "aws_secretsmanager_secret" "config" {
  name                    = "${var.name}/vault/config"
  description             = "Vault license and TLS material"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id = aws_secretsmanager_secret.config.id
  secret_string = jsonencode({
    license = var.vault_license
    ca      = var.ca_cert_pem
    cert    = tls_locally_signed_cert.this.cert_pem
    key     = tls_private_key.this.private_key_pem
  })
}

# Written by the first node after `vault operator init` (root token + recovery key).
# Test environment only: operators and load generators read the root token.
resource "aws_secretsmanager_secret" "init" {
  name                    = "${var.name}/vault/init"
  description             = "Vault init output (root token, recovery keys). Written by vault-0."
  recovery_window_in_days = 0
}

# The first node flips this to "complete" once Vault is initialised (and, in
# the main build, configured for Consul). Consul servers wait for it.
resource "aws_ssm_parameter" "bootstrap" {
  name  = "/${var.name}/vault/bootstrap-status"
  type  = "String"
  value = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

# --- Transport TLS ---------------------------------------------------------

resource "tls_private_key" "this" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "this" {
  private_key_pem = tls_private_key.this.private_key_pem

  subject {
    common_name  = var.fqdn
    organization = var.project
  }

  dns_names    = [var.fqdn, "*.${var.fqdn}", "localhost"]
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "this" {
  cert_request_pem      = tls_cert_request.this.cert_request_pem
  ca_private_key_pem    = var.ca_private_key_pem
  ca_cert_pem           = var.ca_cert_pem
  validity_period_hours = 24 * 180
  early_renewal_hours   = 24 * 14

  allowed_uses = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

# --- Security group ----------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name}-vault"
  description = "Vault servers"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-vault" }
}

resource "aws_vpc_security_group_ingress_rule" "api" {
  security_group_id = aws_security_group.this.id
  description       = "Vault API (clients, NLB health checks, Consul CA provider)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8200
  to_port           = 8200
}

resource "aws_vpc_security_group_ingress_rule" "cluster" {
  security_group_id            = aws_security_group.this.id
  description                  = "Vault cluster (Raft, request forwarding)"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 8201
  to_port                      = 8201
}

# Replication between VPCs: the API (activation, monitoring) and the cluster
# port (WAL streaming, request forwarding). Link cuts use iptables on the
# nodes (repl-cut.sh), not these rules, so Raft inside each cluster is untouched.
resource "aws_vpc_security_group_ingress_rule" "peer" {
  for_each = { for p in setproduct(var.peer_cidrs, [8200, 8201]) : "${p[0]}:${p[1]}" => p }

  security_group_id = aws_security_group.this.id
  description       = "Vault ${each.value[1]} from ${each.value[0]} (replication)"
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
}

# 8201 from inside the VPC too, through the NLB (var.cluster_port_nlb): the
# NLB's health checks and same-VPC secondaries.
resource "aws_vpc_security_group_ingress_rule" "cluster_vpc" {
  count             = var.cluster_port_nlb ? 1 : 0
  security_group_id = aws_security_group.this.id
  description       = "Vault cluster port from the VPC (replication through the NLB)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8201
  to_port           = 8201
}

# --- DNS -----------------------------------------------------------------------

resource "aws_route53_record" "api" {
  zone_id = var.zone_id
  name    = var.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# Per-node names for operators (covered by the *.<fqdn> cert SAN).
resource "aws_route53_record" "node" {
  for_each = aws_instance.this
  zone_id  = var.zone_id
  name     = "${each.key}.${var.fqdn}"
  type     = "A"
  ttl      = 60
  records  = [each.value.private_ip]
}

# --- IAM -----------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  name               = "${var.name}-vault"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "vault" {
  name = "${var.name}-vault"
  role = aws_iam_role.vault.name
}

# SSM Session Manager (no SSH).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Cloud auto-join.
data "aws_iam_policy_document" "describe_instances" {
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "describe_instances" {
  name   = "describe-instances"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.describe_instances.json
}

data "aws_iam_policy_document" "vault" {
  statement {
    sid       = "AutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.unseal.arn]
  }

  statement {
    sid     = "ReadConfig"
    actions = ["secretsmanager:GetSecretValue"]
    resources = compact([
      aws_secretsmanager_secret.config.arn,
      aws_secretsmanager_secret.init.arn,
      try(var.consul_setup.mesh_ca_secret_arn, ""),
    ])
  }

  statement {
    sid       = "WriteInit"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.init.arn]
  }

  statement {
    sid       = "BootstrapStatus"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.bootstrap.arn]
  }

  # AWS auth method (IAM type) resolves bound role ARNs to unique IDs.
  dynamic "statement" {
    for_each = var.consul_setup == null ? [] : [var.consul_setup.role_arn]
    content {
      sid       = "AwsAuthResolveRoles"
      actions   = ["iam:GetRole"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "vault" {
  name   = "vault"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.vault.json
}
