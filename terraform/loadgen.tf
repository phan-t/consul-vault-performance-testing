resource "aws_instance" "loadgen" {
  count = var.loadgen_count

  ami                    = local.ami_id
  instance_type          = var.loadgen_instance_type
  subnet_id              = aws_subnet.private[count.index % length(aws_subnet.private)].id
  iam_instance_profile   = aws_iam_instance_profile.node["loadgen"].name
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

  user_data = replace(templatefile("${path.module}/templates/loadgen.sh.tftpl", {
    common                  = file("${path.module}/templates/common.sh")
    name                    = var.name
    node_name               = "loadgen-${count.index}"
    region                  = var.aws_region
    datacenter              = var.consul_datacenter
    consul_version          = var.consul_version
    vault_version           = var.vault_version
    vault_benchmark_version = var.vault_benchmark_version
    k6_version              = var.k6_version
    vault_fqdn              = local.vault_fqdn
    join_tag                = local.consul_join_tag
    client_secret_id        = aws_secretsmanager_secret.consul_client.arn
    vault_init_secret_id    = aws_secretsmanager_secret.vault_init.arn
    bucket                  = aws_s3_bucket.perf.id
    node_exporter_url       = local.node_exporter_url
    scanner_pattern         = var.scanner_pattern
    scanner_active_cpu      = var.scanner_active_cpu
    arch                    = local.arch
    login_user              = local.login_user
  }), local.user_data_comments, "")

  tags = {
    Name = "${var.name}-loadgen-${count.index}"
    Role = "loadgen"
    Node = "loadgen-${count.index}"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_secretsmanager_secret_version.consul_client,
    aws_iam_role_policy.loadgen,
    aws_iam_role_policy.describe_instances,
    aws_s3_object.perf,
    aws_nat_gateway.this,
    aws_route_table_association.private,
  ]
}
