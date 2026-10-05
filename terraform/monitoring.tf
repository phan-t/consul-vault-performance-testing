locals {
  ec2_sd = [for role, port in { vault = 8200, consul = 8501, node = 9100 } : {
    role = role
    config = [{
      region = var.aws_region
      port   = port
      filters = concat(
        [
          { name = "tag:Project", values = [var.name] },
          { name = "instance-state-name", values = ["running"] },
        ],
        role == "node" ? [] : [{ name = "tag:Role", values = [role] }],
      )
    }]
  }]

  ec2_relabel = [
    { source_labels = ["__meta_ec2_tag_Node"], target_label = "instance" },
    { source_labels = ["__meta_ec2_tag_Role"], target_label = "role" },
    { source_labels = ["__meta_ec2_tag_Voter"], target_label = "voter" },
    { source_labels = ["__meta_ec2_availability_zone"], target_label = "az" },
  ]

  sd = { for s in local.ec2_sd : s.role => s.config }

  prometheus_config = {
    global = {
      scrape_interval     = "10s"
      evaluation_interval = "10s"
    }
    scrape_configs = [
      {
        job_name        = "vault"
        scheme          = "https"
        metrics_path    = "/v1/sys/metrics"
        params          = { format = ["prometheus"] }
        tls_config      = { ca_file = "/etc/prometheus/ca.crt", server_name = local.vault_fqdn }
        ec2_sd_configs  = local.sd["vault"]
        relabel_configs = local.ec2_relabel
      },
      {
        job_name        = "consul"
        scheme          = "https"
        metrics_path    = "/v1/agent/metrics"
        params          = { format = ["prometheus"] }
        authorization   = { credentials_file = "/etc/prometheus/consul-token" }
        tls_config      = { ca_file = "/etc/prometheus/ca.crt", server_name = "server.${var.consul_datacenter}.consul" }
        ec2_sd_configs  = local.sd["consul"]
        relabel_configs = local.ec2_relabel
      },
      {
        job_name        = "node"
        ec2_sd_configs  = local.sd["node"]
        relabel_configs = local.ec2_relabel
      },
    ]
  }
}

resource "aws_instance" "monitoring" {
  count = var.monitoring_enabled ? 1 : 0

  ami                    = local.ami_id
  instance_type          = var.monitoring_instance_type
  subnet_id              = aws_subnet.private[0].id
  iam_instance_profile   = aws_iam_instance_profile.node["monitoring"].name
  vpc_security_group_ids = [aws_security_group.monitoring.id, aws_security_group.common.id]

  metadata_options {
    http_tokens = "required"
    # Prometheus runs in Docker and uses IMDS credentials for EC2 discovery.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = max(var.monitoring_volume_size, local.ami_root_size)
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/monitoring.sh.tftpl", {
    common               = file("${path.module}/templates/common.sh")
    region               = var.aws_region
    monitoring_secret_id = aws_secretsmanager_secret.monitoring.arn
    bucket               = aws_s3_bucket.perf.id
    prometheus_yml       = yamlencode(local.prometheus_config)
    prometheus_image     = var.prometheus_image
    grafana_image        = var.grafana_image
    renderer_image       = var.renderer_image
    node_exporter_url    = local.node_exporter_url
    scanner_pattern      = var.scanner_pattern
    scanner_active_cpu   = var.scanner_active_cpu
    arch                 = local.arch
  })

  tags = {
    Name = "${var.name}-monitoring"
    Role = "monitoring"
    Node = "monitoring"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_secretsmanager_secret_version.monitoring,
    aws_iam_role_policy.monitoring,
    aws_iam_role_policy.describe_instances,
    aws_s3_object.dashboard,
    aws_nat_gateway.this,
    aws_route_table_association.private,
  ]
}
