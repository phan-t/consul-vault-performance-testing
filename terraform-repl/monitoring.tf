# Prometheus and Grafana in the East site, scraping every node in both sites over
# the peering. One Vault job per cluster: each cluster's certificate names its
# own FQDN.

locals {
  vault_jobs = [for k, v in local.clusters : {
    job_name     = "vault-${k}"
    scheme       = "https"
    metrics_path = "/v1/sys/metrics"
    params       = { format = ["prometheus"] }
    tls_config   = { ca_file = "/etc/prometheus/ca.crt", server_name = local.cluster_fqdn[k] }
    ec2_sd_configs = [{
      region = var.regions[v.region]
      port   = 8200
      filters = [
        { name = "tag:Project", values = [var.name] },
        { name = "tag:VaultCluster", values = [local.vault[k].join_tag] },
        { name = "instance-state-name", values = ["running"] },
      ]
    }]
    relabel_configs = concat(local.ec2_relabel, [{ target_label = "cluster", replacement = k }])
  }]

  ec2_relabel = [
    { source_labels = ["__meta_ec2_tag_Node"], target_label = "instance" },
    { source_labels = ["__meta_ec2_tag_Role"], target_label = "role" },
    { source_labels = ["__meta_ec2_tag_Voter"], target_label = "voter" },
    { source_labels = ["__meta_ec2_availability_zone"], target_label = "az" },
  ]

  prometheus_config = {
    global = { scrape_interval = "10s", evaluation_interval = "10s" }
    scrape_configs = concat(local.vault_jobs, [{
      job_name = "node"
      ec2_sd_configs = [for r in distinct([var.regions.east, var.regions.west]) : {
        region  = r
        port    = 9100
        filters = [{ name = "tag:Project", values = [var.name] }, { name = "instance-state-name", values = ["running"] }]
      }]
      relabel_configs = local.ec2_relabel
    }])
  }
}

resource "aws_security_group" "monitoring" {
  provider    = aws.east
  name        = "${var.name}-monitoring"
  description = "Prometheus and Grafana (reach via SSM port forwarding)"
  vpc_id      = module.net_east.vpc_id
  tags        = { Name = "${var.name}-monitoring" }
}

# Both VPCs: k6 on loadgen-1 remote-writes to Prometheus.
resource "aws_vpc_security_group_ingress_rule" "monitoring" {
  provider = aws.east
  for_each = { for p in setproduct(["prometheus:9090", "grafana:3000"], [var.vpc_cidrs.east, var.vpc_cidrs.west]) : "${p[0]}-${p[1]}" => p }

  security_group_id = aws_security_group.monitoring.id
  description       = split(":", each.value[0])[0]
  cidr_ipv4         = each.value[1]
  ip_protocol       = "tcp"
  from_port         = tonumber(split(":", each.value[0])[1])
  to_port           = tonumber(split(":", each.value[0])[1])
}

resource "aws_instance" "monitoring" {
  provider               = aws.east
  ami                    = local.ami.east.id
  instance_type          = var.monitoring_instance_type
  subnet_id              = module.net_east.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.node["monitoring"].name
  vpc_security_group_ids = [aws_security_group.monitoring.id, aws_security_group.common_east.id]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = max(var.monitoring_volume_size, local.root_size.east)
    encrypted   = true
  }

  user_data = replace(templatefile("${path.module}/../terraform/templates/monitoring.sh.tftpl", {
    common               = local.common_sh
    region               = var.regions.east
    monitoring_secret_id = aws_secretsmanager_secret.monitoring.arn
    bucket               = aws_s3_bucket.perf.id
    prometheus_yml       = yamlencode(local.prometheus_config)
    prometheus_image     = var.prometheus_image
    grafana_image        = var.grafana_image
    renderer_image       = var.renderer_image
    node_exporter_url    = local.node_exporter_url
    scanner_pattern      = var.scanner_pattern
    scanner_active_cpu   = var.scanner_active_cpu
    arch                 = var.ami_arch
  }), local.user_data_comments, "")

  tags = { Name = "${var.name}-monitoring", Role = "monitoring", Node = "monitoring" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_secretsmanager_secret_version.monitoring, aws_iam_role_policy.monitoring, aws_s3_object.dashboard, module.net_east]
}

resource "random_password" "renderer_token" {
  length  = 32
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "monitoring" {
  provider                = aws.east
  name                    = "${var.name}/monitoring"
  description             = "Grafana admin password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "monitoring" {
  provider  = aws.east
  secret_id = aws_secretsmanager_secret.monitoring.id
  secret_string = jsonencode({
    ca                     = tls_self_signed_cert.ca.cert_pem
    grafana_admin_password = random_password.grafana_admin.result
    renderer_token         = random_password.renderer_token.result
    consul_metrics_token   = ""
  })
}
