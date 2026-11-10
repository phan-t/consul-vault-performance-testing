# One load generator per site, each against its local cluster: loadgen-0
# (East) drives the primary and runs the campaign; loadgen-1 (West)
# drives the PR secondary.

locals {
  loadgens = {
    "loadgen-0" = { region = "east", cluster = "primary" }
    "loadgen-1" = { region = "west", cluster = "pr-sec" }
  }

  loadgen_user_data = { for k, v in local.loadgens : k => replace(templatefile("${path.module}/templates/loadgen.sh.tftpl", {
    common               = local.common_sh
    name                 = var.name
    node_name            = k
    region               = var.regions[v.region]
    local_cluster        = v.cluster
    vault_addr           = local.vault[v.cluster].addr
    vault_version        = var.vault_version
    k6_version           = var.k6_version
    ca_cert_pem          = tls_self_signed_cert.ca.cert_pem
    clusters_json        = local.clusters_json
    bucket               = aws_s3_bucket.perf.id
    bucket_region        = var.regions.east
    monitoring_secret_id = aws_secretsmanager_secret.monitoring.arn
    node_exporter_url    = local.node_exporter_url
    scanner_pattern      = var.scanner_pattern
    scanner_active_cpu   = var.scanner_active_cpu
    arch                 = var.ami_arch
    login_user           = "ubuntu"
  }), local.user_data_comments, "") }

  loadgen_tags = { for k, v in local.loadgens : k => { Name = "${var.name}-${k}", Role = "loadgen", Node = k } }
}

resource "aws_instance" "loadgen_east" {
  provider               = aws.east
  ami                    = local.ami.east.id
  instance_type          = var.loadgen_instance_type
  subnet_id              = module.net_east.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.node["loadgen"].name
  vpc_security_group_ids = [aws_security_group.common_east.id]
  monitoring             = var.detailed_monitoring
  user_data              = local.loadgen_user_data["loadgen-0"]
  tags                   = local.loadgen_tags["loadgen-0"]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = local.root_size.east
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_iam_role_policy.loadgen, aws_s3_object.perf, module.net_east]
}

resource "aws_instance" "loadgen_west" {
  provider               = aws.west
  ami                    = local.ami.west.id
  instance_type          = var.loadgen_instance_type
  subnet_id              = module.net_west.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.node["loadgen"].name
  vpc_security_group_ids = [aws_security_group.common_west.id]
  monitoring             = var.detailed_monitoring
  user_data              = local.loadgen_user_data["loadgen-1"]
  tags                   = local.loadgen_tags["loadgen-1"]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = local.root_size.west
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_iam_role_policy.loadgen, aws_s3_object.perf, module.net_west]
}
