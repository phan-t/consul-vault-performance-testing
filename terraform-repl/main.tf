locals {
  default_tags = {
    Project     = var.name
    Environment = "perf-test"
    ManagedBy   = "terraform"
  }

  user_data_comments = "/(?m)^[ \\t]*#(?:[^!\\n][^\\n]*)?\\n/"
  common_sh          = file("${path.module}/../terraform/templates/common.sh")
  node_exporter_url  = "https://github.com/prometheus/node_exporter/releases/download/v${var.node_exporter_version}/node_exporter-${var.node_exporter_version}.linux-${var.ami_arch}.tar.gz"

  # The four clusters. role: what replication-setup makes of it.
  #   primary     PR primary and DR primary              (East)
  #   pr-sec      PR secondary, and DR primary of its own DR replica (West)
  #   primary-dr  DR replica of the primary              (West)
  #   pr-sec-dr   DR replica of the PR secondary         (East)
  clusters = {
    primary    = { region = "east", role = "pr_primary", dr_of = "" }
    pr-sec     = { region = "west", role = "pr_secondary", dr_of = "" }
    primary-dr = { region = "west", role = "dr_secondary", dr_of = "primary" }
    pr-sec-dr  = { region = "east", role = "dr_secondary", dr_of = "pr-sec" }
  }
  cluster_fqdn = { for k, v in local.clusters : k => "${k}.vault.${var.private_domain}" }
}

data "aws_caller_identity" "current" {
  provider = aws.east
}

data "aws_ami" "east" {
  provider = aws.east
  filter {
    name   = "name"
    values = [format(var.ami_name_pattern, var.ami_arch)]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = [var.ami_owner]
}

data "aws_ami" "west" {
  provider = aws.west
  filter {
    name   = "name"
    values = [format(var.ami_name_pattern, var.ami_arch)]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = [var.ami_owner]
}

locals {
  ami = { east = data.aws_ami.east, west = data.aws_ami.west }
  root_size = { for r, a in local.ami : r => max(var.root_volume_size,
  one([for b in a.block_device_mappings : b.ebs.volume_size if b.device_name == a.root_device_name])) }
}

# --- Networks and peering ------------------------------------------------------
# One VPC per site. By default both are in Sydney: Melbourne isn't allowed on
# the account. repl/latency.sh adds the delay between them (SITE_RTT_MS).

module "net_east" {
  source             = "../terraform/modules/network"
  providers          = { aws = aws.east }
  name               = "${var.name}-east"
  region             = var.regions.east
  cidr               = var.vpc_cidrs.east
  availability_zones = var.availability_zones.east
}

module "net_west" {
  source             = "../terraform/modules/network"
  providers          = { aws = aws.west }
  name               = "${var.name}-west"
  region             = var.regions.west
  cidr               = var.vpc_cidrs.west
  availability_zones = var.availability_zones.west
}

# VPC peering between the sites: no hourly charge, only data transfer.
resource "aws_vpc_peering_connection" "east_west" {
  provider    = aws.east
  vpc_id      = module.net_east.vpc_id
  peer_vpc_id = module.net_west.vpc_id
  peer_region = var.regions.west == var.regions.east ? null : var.regions.west
  auto_accept = false
  tags        = { Name = "${var.name}-east-west" }
}

resource "aws_vpc_peering_connection_accepter" "east_west" {
  provider                  = aws.west
  vpc_peering_connection_id = aws_vpc_peering_connection.east_west.id
  auto_accept               = true
  tags                      = { Name = "${var.name}-east-west" }
}

resource "aws_route" "east_to_west" {
  provider                  = aws.east
  route_table_id            = module.net_east.private_route_table_id
  destination_cidr_block    = var.vpc_cidrs.west
  vpc_peering_connection_id = aws_vpc_peering_connection.east_west.id
  depends_on                = [aws_vpc_peering_connection_accepter.east_west]
}

resource "aws_route" "west_to_east" {
  provider                  = aws.west
  route_table_id            = module.net_west.private_route_table_id
  destination_cidr_block    = var.vpc_cidrs.east
  vpc_peering_connection_id = aws_vpc_peering_connection.east_west.id
  depends_on                = [aws_vpc_peering_connection_accepter.east_west]
}

locals {
  net = {
    east = { vpc_id = module.net_east.vpc_id, cidr = var.vpc_cidrs.east, subnets = module.net_east.private_subnet_ids, peer = var.vpc_cidrs.west, boot_after = concat(module.net_east.boot_after, [aws_route.east_to_west.id]) }
    west = { vpc_id = module.net_west.vpc_id, cidr = var.vpc_cidrs.west, subnets = module.net_west.private_subnet_ids, peer = var.vpc_cidrs.east, boot_after = concat(module.net_west.boot_after, [aws_route.west_to_east.id]) }
  }
}

# --- DNS: one private zone, both VPCs ------------------------------------------

resource "aws_route53_zone" "private" {
  provider = aws.east
  name     = var.private_domain

  vpc {
    vpc_id     = module.net_east.vpc_id
    vpc_region = var.regions.east
  }

  # The West VPC is added by aws_route53_zone_association.west.
  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_zone_association" "west" {
  provider   = aws.east
  zone_id    = aws_route53_zone.private.zone_id
  vpc_id     = module.net_west.vpc_id
  vpc_region = var.regions.west
}

resource "aws_route53_record" "monitoring" {
  provider = aws.east
  zone_id  = aws_route53_zone.private.zone_id
  name     = "monitoring.${var.private_domain}"
  type     = "A"
  ttl      = 60
  records  = [aws_instance.monitoring.private_ip]
}

# --- Transport TLS CA (one CA: every cluster trusts every other) --------------

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365
  early_renewal_hours   = 24 * 30

  subject {
    common_name  = "${var.name} perf-test CA"
    organization = var.name
  }

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

# --- Common security groups (node_exporter from both VPCs, egress) ------------

resource "aws_security_group" "common_east" {
  provider    = aws.east
  name        = "${var.name}-common"
  description = "Common rules for all perf nodes"
  vpc_id      = module.net_east.vpc_id
  tags        = { Name = "${var.name}-common" }
}

resource "aws_security_group" "common_west" {
  provider    = aws.west
  name        = "${var.name}-common"
  description = "Common rules for all perf nodes"
  vpc_id      = module.net_west.vpc_id
  tags        = { Name = "${var.name}-common" }
}

resource "aws_vpc_security_group_ingress_rule" "node_exporter_east" {
  provider          = aws.east
  for_each          = toset([var.vpc_cidrs.east, var.vpc_cidrs.west])
  security_group_id = aws_security_group.common_east.id
  description       = "node_exporter"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 9100
  to_port           = 9100
}

resource "aws_vpc_security_group_ingress_rule" "node_exporter_west" {
  provider          = aws.west
  for_each          = toset([var.vpc_cidrs.east, var.vpc_cidrs.west])
  security_group_id = aws_security_group.common_west.id
  description       = "node_exporter"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 9100
  to_port           = 9100
}

resource "aws_vpc_security_group_egress_rule" "common_east" {
  provider          = aws.east
  security_group_id = aws_security_group.common_east.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "common_west" {
  provider          = aws.west
  security_group_id = aws_security_group.common_west.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

locals {
  common_sg = { east = aws_security_group.common_east.id, west = aws_security_group.common_west.id }
}
