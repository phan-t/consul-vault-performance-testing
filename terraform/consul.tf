# Consul Enterprise: var.consul_voter_count voters + var.consul_read_replica_count
# read replicas (non-voting servers). Connect CA = Vault PKI.

locals {
  consul_connect_config = {
    connect = {
      enabled     = true
      ca_provider = "vault"
      ca_config = {
        address               = "https://${local.vault_fqdn}:8200"
        ca_file               = "/etc/consul.d/tls/ca.crt"
        root_pki_path         = local.mesh_pki_path
        intermediate_pki_path = local.connect_inter_pki_path
        leaf_cert_ttl         = var.consul_connect_ca.leaf_cert_ttl
        intermediate_cert_ttl = var.consul_connect_ca.intermediate_cert_ttl
        private_key_type      = var.consul_connect_ca.private_key_type
        private_key_bits      = var.consul_connect_ca.private_key_bits
        csr_max_per_second    = var.consul_connect_ca.csr_max_per_second
        csr_max_concurrent    = var.consul_connect_ca.csr_max_concurrent
        auth_method = {
          type       = "aws"
          mount_path = "aws"
          params = {
            role         = "consul-server"
            region       = var.aws_region
            sts_endpoint = "https://sts.${var.aws_region}.amazonaws.com"
          }
        }
      }
    }
  }
}

resource "aws_instance" "consul" {
  for_each = { for n in local.consul_nodes : n.name => n }

  ami                    = local.ami_id
  instance_type          = var.consul_instance_type
  subnet_id              = aws_subnet.private[each.value.index % length(aws_subnet.private)].id
  iam_instance_profile   = aws_iam_instance_profile.node["consul"].name
  vpc_security_group_ids = [aws_security_group.consul.id, aws_security_group.common.id]
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
    volume_size           = var.consul_data_volume.size
    iops                  = var.consul_data_volume.iops
    throughput            = var.consul_data_volume.throughput
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/consul-server.sh.tftpl", {
    common                = file("${path.module}/templates/common.sh")
    name                  = var.name
    node_name             = each.key
    voter                 = each.value.voter
    voter_count           = var.consul_voter_count
    bootstrap             = each.value.index == 0
    region                = var.aws_region
    datacenter            = var.consul_datacenter
    consul_version        = var.consul_version
    join_tag              = local.consul_join_tag
    server_secret_id      = aws_secretsmanager_secret.consul_server.arn
    bootstrap_param       = aws_ssm_parameter.vault_bootstrap.name
    connect_json          = jsonencode(local.consul_connect_config)
    rpc_handshake_timeout = var.consul_rpc_handshake_timeout
    node_exporter_url     = local.node_exporter_url
    scanner_pattern       = var.scanner_pattern
    scanner_active_cpu    = var.scanner_active_cpu
    arch                  = local.arch
  })

  tags = {
    Name          = "${var.name}-${each.key}"
    Role          = "consul"
    Node          = each.key
    Voter         = tostring(each.value.voter)
    ConsulCluster = local.consul_join_tag
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_secretsmanager_secret_version.consul_server,
    aws_iam_role_policy.consul,
    aws_iam_role_policy.describe_instances,
    aws_nat_gateway.this,
    aws_route_table_association.private,
  ]
}

# --- Internal NLB for the HTTPS API / UI ------------------------------------

resource "aws_lb" "consul" {
  name                             = "${var.name}-consul"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = aws_subnet.private[*].id
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "consul" {
  name                 = "${var.name}-consul"
  port                 = 8501
  protocol             = "TCP"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    protocol            = "TCP"
    port                = "8501"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "consul" {
  load_balancer_arn = aws_lb.consul.arn
  port              = 8501
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.consul.arn
  }
}

resource "aws_lb_target_group_attachment" "consul" {
  for_each         = aws_instance.consul
  target_group_arn = aws_lb_target_group.consul.arn
  target_id        = each.value.id
  port             = 8501
}
