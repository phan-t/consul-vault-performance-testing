# Vault Enterprise: var.vault_voter_count voters + var.vault_non_voter_count
# extra nodes (performance standbys): redundancy zone spares, or permanent
# non-voters without var.vault_redundancy_zones. The cluster itself (nodes,
# NLB, KMS, bootstrap secrets, TLS, security group, DNS, IAM) is
# modules/vault-cluster, which the replication build (../terraform-repl) also
# uses, four times.

module "vault" {
  source = "./modules/vault-cluster"

  name                     = var.name
  project                  = var.name
  region                   = var.aws_region
  vpc_id                   = aws_vpc.this.id
  vpc_cidr                 = var.vpc_cidr
  subnet_ids               = aws_subnet.private[*].id
  extra_security_group_ids = [aws_security_group.common.id]

  ami_id              = local.ami_id
  arch                = local.arch
  root_volume_size    = local.root_size
  instance_type       = var.vault_instance_type
  data_volume         = var.vault_data_volume
  detailed_monitoring = var.detailed_monitoring

  voter_count      = var.vault_voter_count
  non_voter_count  = var.vault_non_voter_count
  redundancy_zones = var.vault_redundancy_zones
  non_voters_start = var.vault_non_voters_start
  vault_version    = var.vault_version
  vault_license    = var.vault_license
  audit_enabled    = var.vault_audit_enabled
  alb_listener     = var.vault_alb

  fqdn               = local.vault_fqdn
  zone_id            = aws_route53_zone.private.zone_id
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem

  consul_setup = {
    role_arn           = aws_iam_role.node["consul"].arn
    mesh_pki_path      = local.mesh_pki_path
    mesh_ca_secret_arn = aws_secretsmanager_secret.mesh_ca.arn
    inter_pki_path     = local.connect_inter_pki_path
  }

  common_sh          = file("${path.module}/templates/common.sh")
  user_data_comments = local.user_data_comments
  node_exporter_url  = local.node_exporter_url
  scanner_pattern    = var.scanner_pattern
  scanner_active_cpu = var.scanner_active_cpu

  boot_after = concat(
    [aws_secretsmanager_secret_version.mesh_ca.id],
    aws_nat_gateway.this[*].id,
    aws_route_table_association.private[*].id,
  )
}

# The cluster moved into modules/vault-cluster without changing anything:
# `terraform plan` on an existing build shows no changes.
moved {
  from = aws_instance.vault
  to   = module.vault.aws_instance.this
}
moved {
  from = aws_lb.vault
  to   = module.vault.aws_lb.this
}
moved {
  from = aws_lb_target_group.vault
  to   = module.vault.aws_lb_target_group.this
}
moved {
  from = aws_lb_listener.vault
  to   = module.vault.aws_lb_listener.api
}
moved {
  from = aws_lb_target_group_attachment.vault
  to   = module.vault.aws_lb_target_group_attachment.this
}
moved {
  from = aws_kms_key.vault_unseal
  to   = module.vault.aws_kms_key.unseal
}
moved {
  from = aws_kms_alias.vault_unseal
  to   = module.vault.aws_kms_alias.unseal
}
moved {
  from = aws_secretsmanager_secret.vault_config
  to   = module.vault.aws_secretsmanager_secret.config
}
moved {
  from = aws_secretsmanager_secret_version.vault_config
  to   = module.vault.aws_secretsmanager_secret_version.config
}
moved {
  from = aws_secretsmanager_secret.vault_init
  to   = module.vault.aws_secretsmanager_secret.init
}
moved {
  from = aws_ssm_parameter.vault_bootstrap
  to   = module.vault.aws_ssm_parameter.bootstrap
}
moved {
  from = tls_private_key.vault
  to   = module.vault.tls_private_key.this
}
moved {
  from = tls_cert_request.vault
  to   = module.vault.tls_cert_request.this
}
moved {
  from = tls_locally_signed_cert.vault
  to   = module.vault.tls_locally_signed_cert.this
}
moved {
  from = aws_security_group.vault
  to   = module.vault.aws_security_group.this
}
moved {
  from = aws_vpc_security_group_ingress_rule.vault_api
  to   = module.vault.aws_vpc_security_group_ingress_rule.api
}
moved {
  from = aws_vpc_security_group_ingress_rule.vault_cluster
  to   = module.vault.aws_vpc_security_group_ingress_rule.cluster
}
moved {
  from = aws_route53_record.vault
  to   = module.vault.aws_route53_record.api
}
moved {
  from = aws_route53_record.vault_node
  to   = module.vault.aws_route53_record.node
}
moved {
  from = aws_iam_role.node["vault"]
  to   = module.vault.aws_iam_role.vault
}
moved {
  from = aws_iam_instance_profile.node["vault"]
  to   = module.vault.aws_iam_instance_profile.vault
}
moved {
  from = aws_iam_role_policy_attachment.ssm_core["vault"]
  to   = module.vault.aws_iam_role_policy_attachment.ssm_core
}
moved {
  from = aws_iam_role_policy.describe_instances["vault"]
  to   = module.vault.aws_iam_role_policy.describe_instances
}
moved {
  from = aws_iam_role_policy.vault
  to   = module.vault.aws_iam_role_policy.vault
}

# --- T16 path C (opt-in, var.vault_alb): internal ALB, HTTP/2 to targets -----
# The NLB above balances per TCP connection, so the Consul leader's one pooled
# HTTP/2 connection lands on one Vault node. An ALB terminates TLS and balances
# each HTTP/2 request, so the same connection can reach every node (issue #14).
# Its target is a second Vault listener (8202): 8200 and the NLB are unchanged.

resource "aws_acm_certificate" "vault_alb" {
  count             = var.vault_alb ? 1 : 0
  private_key       = module.vault.tls_private_key_pem
  certificate_body  = module.vault.tls_cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem
  tags              = { Name = "${var.name}-vault-alb" }
}

resource "aws_lb" "vault_alb" {
  count              = var.vault_alb ? 1 : 0
  name               = "${var.name}-vault-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = aws_subnet.private[*].id
  security_groups    = [aws_security_group.vault_alb[0].id]
  # Longer than Go's 90 s idle-connection timeout, so the client closes idle
  # connections first: a sign (a POST) sent on a connection the ALB already
  # closed isn't retried.
  idle_timeout = 120
}

resource "aws_lb_target_group" "vault_alb" {
  count                = var.vault_alb ? 1 : 0
  name                 = "${var.name}-vault-alb"
  port                 = 8202
  protocol             = "HTTPS"
  protocol_version     = "HTTP2"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    protocol            = "HTTPS"
    port                = "8202"
    path                = "/v1/sys/health?standbyok=true&perfstandbyok=true"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "vault_alb" {
  count             = var.vault_alb ? 1 : 0
  load_balancer_arn = aws_lb.vault_alb[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.vault_alb[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault_alb[0].arn
  }
}

resource "aws_lb_target_group_attachment" "vault_alb" {
  for_each         = { for k, v in module.vault.instances : k => v.id if var.vault_alb }
  target_group_arn = aws_lb_target_group.vault_alb[0].arn
  target_id        = each.value
  port             = 8202
}
