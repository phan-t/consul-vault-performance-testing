# No inbound access from outside the VPC. Operators use SSM Session Manager
# (shell and port forwarding), so no SSH keys or bastion are needed.

resource "aws_security_group" "vault" {
  name        = "${var.name}-vault"
  description = "Vault servers"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-vault" }
}

resource "aws_vpc_security_group_ingress_rule" "vault_api" {
  security_group_id = aws_security_group.vault.id
  description       = "Vault API (clients, NLB health checks, Consul CA provider)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8200
  to_port           = 8200
}

resource "aws_vpc_security_group_ingress_rule" "vault_cluster" {
  security_group_id            = aws_security_group.vault.id
  description                  = "Vault cluster (Raft, request forwarding)"
  referenced_security_group_id = aws_security_group.vault.id
  ip_protocol                  = "tcp"
  from_port                    = 8201
  to_port                      = 8201
}

resource "aws_security_group" "consul" {
  name        = "${var.name}-consul"
  description = "Consul servers and client agents"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-consul" }
}

resource "aws_vpc_security_group_ingress_rule" "consul_tcp" {
  for_each = {
    server_rpc = [8300, 8300]
    serf       = [8301, 8302]
    api_grpc   = [8500, 8503]
    dns        = [8600, 8600]
  }

  security_group_id = aws_security_group.consul.id
  description       = "Consul ${each.key}"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = each.value[0]
  to_port           = each.value[1]
}

resource "aws_vpc_security_group_ingress_rule" "consul_udp" {
  for_each = {
    serf = [8301, 8302]
    dns  = [8600, 8600]
  }

  security_group_id = aws_security_group.consul.id
  description       = "Consul ${each.key} (udp)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "udp"
  from_port         = each.value[0]
  to_port           = each.value[1]
}

# Applied to every node: node_exporter scrape + egress.
resource "aws_security_group" "common" {
  name        = "${var.name}-common"
  description = "Common rules for all perf nodes"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-common" }
}

resource "aws_vpc_security_group_ingress_rule" "node_exporter" {
  security_group_id = aws_security_group.common.id
  description       = "node_exporter"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 9100
  to_port           = 9100
}

resource "aws_vpc_security_group_egress_rule" "common_all" {
  security_group_id = aws_security_group.common.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring"
  description = "Prometheus and Grafana (reach via SSM port forwarding)"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-monitoring" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring" {
  for_each = { prometheus = 9090, grafana = 3000 }

  security_group_id = aws_security_group.monitoring.id
  description       = each.key
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# T16 path C (var.vault_alb): the ALB takes HTTPS from the VPC and reaches
# Vault's second listener (8202).
resource "aws_security_group" "vault_alb" {
  count       = var.vault_alb ? 1 : 0
  name        = "${var.name}-vault-alb"
  description = "Vault ALB (T16 path C)"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-vault-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "vault_alb_https" {
  count             = var.vault_alb ? 1 : 0
  security_group_id = aws_security_group.vault_alb[0].id
  description       = "HTTPS (Consul CA provider)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "vault_alb_targets" {
  count                        = var.vault_alb ? 1 : 0
  security_group_id            = aws_security_group.vault_alb[0].id
  description                  = "Vault ALB listener and health checks"
  referenced_security_group_id = aws_security_group.vault.id
  ip_protocol                  = "tcp"
  from_port                    = 8202
  to_port                      = 8202
}

resource "aws_vpc_security_group_ingress_rule" "vault_alb_listener" {
  count                        = var.vault_alb ? 1 : 0
  security_group_id            = aws_security_group.vault.id
  description                  = "Vault ALB listener (T16 path C)"
  referenced_security_group_id = aws_security_group.vault_alb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8202
  to_port                      = 8202
}
