# Optional public HTTPS endpoints on one ALB (host-based routing):
#   grafana-<name>.<zone> -> monitoring node :3000   (grafana_allowed_cidrs)
#   vault-<name>.<zone>   -> Vault nodes :8200 HTTPS  (ui_allowed_cidrs, expose_vault_ui)
#   consul-<name>.<zone>  -> Consul servers :8501 HTTPS (ui_allowed_cidrs, expose_consul_ui)
# Everything else gets a 404. Backends stay in private subnets.
# Enabled when var.grafana_public_zone is set (and monitoring is enabled).

locals {
  grafana_public   = var.monitoring_enabled && var.grafana_public_zone != ""
  grafana_hostname = var.grafana_public_hostname != "" ? var.grafana_public_hostname : "grafana-${var.name}"
  grafana_fqdn     = local.grafana_public ? "${local.grafana_hostname}.${var.grafana_public_zone}" : ""

  vault_public  = local.grafana_public && var.expose_vault_ui
  consul_public = local.grafana_public && var.expose_consul_ui

  vault_public_fqdn  = local.vault_public ? "vault-${var.name}.${var.grafana_public_zone}" : ""
  consul_public_fqdn = local.consul_public ? "consul-${var.name}.${var.grafana_public_zone}" : ""

  public_fqdns = compact([local.grafana_fqdn, local.vault_public_fqdn, local.consul_public_fqdn])

  # Ports the ALB may reach inside the VPC.
  alb_backend_ports = concat(
    local.grafana_public ? [3000] : [],
    local.vault_public ? [8200] : [],
    local.consul_public ? [8501] : [],
  )

  alb_ingress_cidrs = distinct(concat(
    var.grafana_allowed_cidrs,
    local.vault_public || local.consul_public ? var.ui_allowed_cidrs : [],
  ))
}

data "aws_route53_zone" "public" {
  count        = local.grafana_public ? 1 : 0
  name         = var.grafana_public_zone
  private_zone = false
}

# --- Certificate (DNS-validated in the public zone) --------------------------

resource "aws_acm_certificate" "grafana" {
  count                     = local.grafana_public ? 1 : 0
  domain_name               = local.grafana_fqdn
  subject_alternative_names = compact([local.vault_public_fqdn, local.consul_public_fqdn])
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Keyed by the configured names (known at plan time) rather than by the
# certificate's validation options, which are unknown while it is replaced.
resource "aws_route53_record" "grafana_cert_validation" {
  for_each = toset(local.public_fqdns)

  zone_id = data.aws_route53_zone.public[0].zone_id
  name = one([for o in aws_acm_certificate.grafana[0].domain_validation_options :
  o.resource_record_name if o.domain_name == each.key])
  type = one([for o in aws_acm_certificate.grafana[0].domain_validation_options :
  o.resource_record_type if o.domain_name == each.key])
  records = [one([for o in aws_acm_certificate.grafana[0].domain_validation_options :
  o.resource_record_value if o.domain_name == each.key])]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "grafana" {
  count                   = local.grafana_public ? 1 : 0
  certificate_arn         = aws_acm_certificate.grafana[0].arn
  validation_record_fqdns = [for r in aws_route53_record.grafana_cert_validation : r.fqdn]
}

# --- ALB -----------------------------------------------------------------------

resource "aws_security_group" "grafana_alb" {
  count       = local.grafana_public ? 1 : 0
  name        = "${var.name}-grafana-alb"
  description = "Public Grafana ALB"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-public-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "grafana_alb" {
  for_each = local.grafana_public ? {
    for pair in setproduct(local.alb_ingress_cidrs, [80, 443]) : "${pair[0]}-${pair[1]}" => pair
  } : {}

  security_group_id = aws_security_group.grafana_alb[0].id
  description       = each.value[1] == 443 ? "HTTPS" : "HTTP redirect"
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
}

resource "aws_vpc_security_group_egress_rule" "grafana_alb" {
  count             = local.grafana_public ? 1 : 0
  security_group_id = aws_security_group.grafana_alb[0].id
  description       = "To Grafana on the monitoring node"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
}

resource "aws_vpc_security_group_egress_rule" "public_alb_ui" {
  for_each = toset([for p in local.alb_backend_ports : tostring(p) if p != 3000])

  security_group_id = aws_security_group.grafana_alb[0].id
  description       = "To ${each.key == "8200" ? "Vault" : "Consul"} HTTPS"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
}

resource "aws_lb" "grafana" {
  count                      = local.grafana_public ? 1 : 0
  name                       = "${var.name}-grafana"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.grafana_alb[0].id]
  drop_invalid_header_fields = true
}

# --- Grafana backend -----------------------------------------------------------

resource "aws_lb_target_group" "grafana" {
  count                = local.grafana_public ? 1 : 0
  name                 = "${var.name}-grafana"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "grafana" {
  count            = local.grafana_public ? 1 : 0
  target_group_arn = aws_lb_target_group.grafana[0].arn
  target_id        = aws_instance.monitoring[0].id
  port             = 3000
}

# --- Vault backend (HTTPS to every node; standbys forward/serve as needed) -----

resource "aws_lb_target_group" "vault_public" {
  count                = local.vault_public ? 1 : 0
  name                 = "${var.name}-vault-ui"
  port                 = 8200
  protocol             = "HTTPS"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    protocol            = "HTTPS"
    path                = "/v1/sys/health?standbyok=true&perfstandbyok=true"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "vault_public" {
  for_each         = local.vault_public ? aws_instance.vault : {}
  target_group_arn = aws_lb_target_group.vault_public[0].arn
  target_id        = each.value.id
  port             = 8200
}

# --- Consul backend (HTTPS API/UI on the servers) ------------------------------

resource "aws_lb_target_group" "consul_public" {
  count                = local.consul_public ? 1 : 0
  name                 = "${var.name}-consul-ui"
  port                 = 8501
  protocol             = "HTTPS"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  # Sticky so the UI's blocking queries stay on one server.
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 3600
  }

  health_check {
    protocol            = "HTTPS"
    path                = "/v1/status/leader"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "consul_public" {
  for_each         = local.consul_public ? aws_instance.consul : {}
  target_group_arn = aws_lb_target_group.consul_public[0].arn
  target_id        = each.value.id
  port             = 8501
}

# --- Listeners and host rules --------------------------------------------------

resource "aws_lb_listener" "grafana_https" {
  count             = local.grafana_public ? 1 : 0
  load_balancer_arn = aws_lb.grafana[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.grafana[0].certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

locals {
  public_hosts = merge(
    local.grafana_public ? {
      grafana = { priority = 10, fqdn = local.grafana_fqdn, cidrs = var.grafana_allowed_cidrs, tg = aws_lb_target_group.grafana[0].arn }
    } : {},
    local.vault_public ? {
      vault = { priority = 20, fqdn = local.vault_public_fqdn, cidrs = var.ui_allowed_cidrs, tg = aws_lb_target_group.vault_public[0].arn }
    } : {},
    local.consul_public ? {
      consul = { priority = 30, fqdn = local.consul_public_fqdn, cidrs = var.ui_allowed_cidrs, tg = aws_lb_target_group.consul_public[0].arn }
    } : {},
  )
}

resource "aws_lb_listener_rule" "public_host" {
  for_each = local.public_hosts

  listener_arn = aws_lb_listener.grafana_https[0].arn
  priority     = each.value.priority

  condition {
    host_header {
      values = [each.value.fqdn]
    }
  }

  condition {
    source_ip {
      values = each.value.cidrs
    }
  }

  action {
    type             = "forward"
    target_group_arn = each.value.tg
  }
}

resource "aws_lb_listener" "grafana_http" {
  count             = local.grafana_public ? 1 : 0
  load_balancer_arn = aws_lb.grafana[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

# --- DNS -------------------------------------------------------------------------

resource "aws_route53_record" "grafana_public" {
  count   = local.grafana_public ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = local.grafana_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.grafana[0].dns_name
    zone_id                = aws_lb.grafana[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ui_public" {
  for_each = { for k, v in local.public_hosts : k => v if k != "grafana" }

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = each.value.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.grafana[0].dns_name
    zone_id                = aws_lb.grafana[0].zone_id
    evaluate_target_health = true
  }
}
