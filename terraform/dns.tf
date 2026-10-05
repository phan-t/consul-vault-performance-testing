resource "aws_route53_zone" "private" {
  name = var.private_domain

  vpc {
    vpc_id = aws_vpc.this.id
  }
}

resource "aws_route53_record" "vault" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.vault_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.vault.dns_name
    zone_id                = aws_lb.vault.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "consul" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.consul_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.consul.dns_name
    zone_id                = aws_lb.consul.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "monitoring" {
  count   = var.monitoring_enabled ? 1 : 0
  zone_id = aws_route53_zone.private.zone_id
  name    = "monitoring.${var.private_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.monitoring[0].private_ip]
}

# Per-node names for operators (covered by the *.vault / *.consul cert SANs).
resource "aws_route53_record" "vault_node" {
  for_each = aws_instance.vault
  zone_id  = aws_route53_zone.private.zone_id
  name     = "${each.key}.${local.vault_fqdn}"
  type     = "A"
  ttl      = 60
  records  = [each.value.private_ip]
}

resource "aws_route53_record" "consul_node" {
  for_each = aws_instance.consul
  zone_id  = aws_route53_zone.private.zone_id
  name     = "${each.key}.${local.consul_fqdn}"
  type     = "A"
  ttl      = 60
  records  = [each.value.private_ip]
}
