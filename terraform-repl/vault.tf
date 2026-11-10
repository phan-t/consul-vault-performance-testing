# The four Vault clusters (modules/vault-cluster, the same module as the main
# build). Each is initialised on its own; replication-setup.sh then activates
# PR and DR in order (perf/scripts/repl/). Every cluster has the 8201 NLB
# listener, so any of them can be a primary after a promotion.

module "vault_primary" {
  source    = "../terraform/modules/vault-cluster"
  providers = { aws = aws.east }

  name        = "${var.name}-primary"
  project     = var.name
  node_prefix = "primary"
  region      = var.regions.east

  vpc_id                   = local.net.east.vpc_id
  vpc_cidr                 = local.net.east.cidr
  peer_cidrs               = [local.net.east.peer]
  subnet_ids               = local.net.east.subnets
  extra_security_group_ids = [local.common_sg.east]
  cluster_port_nlb         = true
  health_check_extra       = "&drsecondarycode=200&performancestandbycode=200"

  ami_id              = local.ami.east.id
  arch                = var.ami_arch
  root_volume_size    = local.root_size.east
  instance_type       = var.vault_instance_type
  data_volume         = var.vault_data_volume
  detailed_monitoring = var.detailed_monitoring

  voter_count     = var.vault_voter_count
  non_voter_count = 0
  vault_version   = var.vault_version
  vault_license   = var.vault_license
  audit_enabled   = var.vault_audit_enabled

  logshipper_buffer_length = var.logshipper_buffer_length
  logshipper_buffer_size   = var.logshipper_buffer_size

  fqdn               = local.cluster_fqdn["primary"]
  zone_id            = aws_route53_zone.private.zone_id
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem

  common_sh          = local.common_sh
  user_data_comments = local.user_data_comments
  node_exporter_url  = local.node_exporter_url
  scanner_pattern    = var.scanner_pattern
  scanner_active_cpu = var.scanner_active_cpu
  boot_after         = local.net.east.boot_after
}

module "vault_pr_sec" {
  source    = "../terraform/modules/vault-cluster"
  providers = { aws = aws.west }

  name        = "${var.name}-pr-sec"
  project     = var.name
  node_prefix = "pr-sec"
  region      = var.regions.west

  vpc_id                   = local.net.west.vpc_id
  vpc_cidr                 = local.net.west.cidr
  peer_cidrs               = [local.net.west.peer]
  subnet_ids               = local.net.west.subnets
  extra_security_group_ids = [local.common_sg.west]
  cluster_port_nlb         = true
  health_check_extra       = "&drsecondarycode=200&performancestandbycode=200"

  ami_id              = local.ami.west.id
  arch                = var.ami_arch
  root_volume_size    = local.root_size.west
  instance_type       = var.vault_instance_type
  data_volume         = var.vault_data_volume
  detailed_monitoring = var.detailed_monitoring

  voter_count     = var.vault_voter_count
  non_voter_count = 0
  vault_version   = var.vault_version
  vault_license   = var.vault_license
  audit_enabled   = var.vault_audit_enabled

  logshipper_buffer_length = var.logshipper_buffer_length
  logshipper_buffer_size   = var.logshipper_buffer_size

  fqdn               = local.cluster_fqdn["pr-sec"]
  zone_id            = aws_route53_zone.private.zone_id
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem

  common_sh          = local.common_sh
  user_data_comments = local.user_data_comments
  node_exporter_url  = local.node_exporter_url
  scanner_pattern    = var.scanner_pattern
  scanner_active_cpu = var.scanner_active_cpu
  boot_after         = local.net.west.boot_after
}

module "vault_primary_dr" {
  source    = "../terraform/modules/vault-cluster"
  providers = { aws = aws.west }

  name        = "${var.name}-primary-dr"
  project     = var.name
  node_prefix = "primary-dr"
  region      = var.regions.west

  vpc_id                   = local.net.west.vpc_id
  vpc_cidr                 = local.net.west.cidr
  peer_cidrs               = [local.net.west.peer]
  subnet_ids               = local.net.west.subnets
  extra_security_group_ids = [local.common_sg.west]
  cluster_port_nlb         = true
  health_check_extra       = "&drsecondarycode=200&performancestandbycode=200"

  ami_id              = local.ami.west.id
  arch                = var.ami_arch
  root_volume_size    = local.root_size.west
  instance_type       = var.vault_instance_type
  data_volume         = var.vault_data_volume
  detailed_monitoring = var.detailed_monitoring

  voter_count     = var.vault_voter_count
  non_voter_count = 0
  vault_version   = var.vault_version
  vault_license   = var.vault_license
  audit_enabled   = var.vault_audit_enabled

  logshipper_buffer_length = var.logshipper_buffer_length
  logshipper_buffer_size   = var.logshipper_buffer_size

  fqdn               = local.cluster_fqdn["primary-dr"]
  zone_id            = aws_route53_zone.private.zone_id
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem

  common_sh          = local.common_sh
  user_data_comments = local.user_data_comments
  node_exporter_url  = local.node_exporter_url
  scanner_pattern    = var.scanner_pattern
  scanner_active_cpu = var.scanner_active_cpu
  boot_after         = local.net.west.boot_after
}

module "vault_pr_sec_dr" {
  source    = "../terraform/modules/vault-cluster"
  providers = { aws = aws.east }

  name        = "${var.name}-pr-sec-dr"
  project     = var.name
  node_prefix = "pr-sec-dr"
  region      = var.regions.east

  vpc_id                   = local.net.east.vpc_id
  vpc_cidr                 = local.net.east.cidr
  peer_cidrs               = [local.net.east.peer]
  subnet_ids               = local.net.east.subnets
  extra_security_group_ids = [local.common_sg.east]
  cluster_port_nlb         = true
  health_check_extra       = "&drsecondarycode=200&performancestandbycode=200"

  ami_id              = local.ami.east.id
  arch                = var.ami_arch
  root_volume_size    = local.root_size.east
  instance_type       = var.vault_instance_type
  data_volume         = var.vault_data_volume
  detailed_monitoring = var.detailed_monitoring

  voter_count     = var.vault_voter_count
  non_voter_count = 0
  vault_version   = var.vault_version
  vault_license   = var.vault_license
  audit_enabled   = var.vault_audit_enabled

  logshipper_buffer_length = var.logshipper_buffer_length
  logshipper_buffer_size   = var.logshipper_buffer_size

  fqdn               = local.cluster_fqdn["pr-sec-dr"]
  zone_id            = aws_route53_zone.private.zone_id
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem

  common_sh          = local.common_sh
  user_data_comments = local.user_data_comments
  node_exporter_url  = local.node_exporter_url
  scanner_pattern    = var.scanner_pattern
  scanner_active_cpu = var.scanner_active_cpu
  boot_after         = local.net.east.boot_after
}

locals {
  vault = {
    primary    = module.vault_primary
    pr-sec     = module.vault_pr_sec
    primary-dr = module.vault_primary_dr
    pr-sec-dr  = module.vault_pr_sec_dr
  }

  # Written to every load generator as /opt/perf/clusters.json: what the
  # repl scripts need to reach and identify each cluster. No secrets.
  clusters_json = jsonencode({ for k, v in local.clusters : k => {
    region          = var.regions[v.region]
    role            = v.role
    dr_of           = v.dr_of
    addr            = local.vault[k].addr
    cluster_addr    = local.vault[k].cluster_addr
    fqdn            = local.vault[k].fqdn
    join_tag        = local.vault[k].join_tag
    init_secret     = local.vault[k].init_secret_arn
    bootstrap_param = local.vault[k].bootstrap_param_name
    tg_arn          = local.vault[k].nlb_target_group_arn
    site            = v.region
    site_cidr       = local.net[v.region].cidr
    peer_cidr       = local.net[v.region].peer
  } })
}
