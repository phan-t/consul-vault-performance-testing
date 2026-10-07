data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  roles = toset(["vault", "consul", "loadgen", "monitoring"])
}

resource "aws_iam_role" "node" {
  for_each           = local.roles
  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.roles
  name     = "${var.name}-${each.key}"
  role     = aws_iam_role.node[each.key].name
}

# SSM Session Manager on every node (no SSH).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each   = local.roles
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Cloud auto-join (Vault/Consul) and Prometheus EC2 discovery.
data "aws_iam_policy_document" "describe_instances" {
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "describe_instances" {
  for_each = local.roles
  name     = "describe-instances"
  role     = aws_iam_role.node[each.key].id
  policy   = data.aws_iam_policy_document.describe_instances.json
}

# --- Vault -----------------------------------------------------------------

data "aws_iam_policy_document" "vault" {
  statement {
    sid       = "AutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.vault_unseal.arn]
  }

  statement {
    sid     = "ReadConfig"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.vault_config.arn,
      aws_secretsmanager_secret.vault_init.arn,
      aws_secretsmanager_secret.mesh_ca.arn,
    ]
  }

  statement {
    sid       = "WriteInit"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.vault_init.arn]
  }

  statement {
    sid       = "BootstrapStatus"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.vault_bootstrap.arn]
  }

  # AWS auth method (IAM type) resolves bound role ARNs to unique IDs.
  statement {
    sid       = "AwsAuthResolveRoles"
    actions   = ["iam:GetRole"]
    resources = [aws_iam_role.node["consul"].arn]
  }
}

resource "aws_iam_role_policy" "vault" {
  name   = "vault"
  role   = aws_iam_role.node["vault"].id
  policy = data.aws_iam_policy_document.vault.json
}

# --- Consul ----------------------------------------------------------------

data "aws_iam_policy_document" "consul" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.consul_server.arn]
  }

  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.vault_bootstrap.arn]
  }
}

resource "aws_iam_role_policy" "consul" {
  name   = "consul"
  role   = aws_iam_role.node["consul"].id
  policy = data.aws_iam_policy_document.consul.json
}

# --- Load generators -------------------------------------------------------

data "aws_iam_policy_document" "loadgen" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.consul_client.arn,
      aws_secretsmanager_secret.vault_init.arn,
      # Grafana credentials for run annotations and result exports.
      aws_secretsmanager_secret.monitoring.arn,
    ]
  }

  # NLB target health, polled during failure tests (lib.sh nlb_watch_*): how
  # long the NLB keeps sending requests to a frozen or restarting Vault node.
  statement {
    actions   = ["elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth"]
    resources = ["*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.perf.arn]
  }

  statement {
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.perf.arn}/assets/*",
      # summarise.sh reads back every load generator's results for a run.
      "${aws_s3_bucket.perf.arn}/results/*",
    ]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.perf.arn}/results/*"]
  }
}

# run-plan.sh runs unattended: it settles every node before the campaign (runs
# due apt jobs) and starts held Vault non-voters for T9-V, over SSM Run Command.
# Scoped to this project's instances and the shell-script document.
data "aws_iam_policy_document" "loadgen_ssm" {
  statement {
    sid     = "RunShellOnProjectInstances"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.name]
    }
  }

  statement {
    sid       = "ShellDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "CommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "loadgen_ssm" {
  name   = "run-plan-ssm"
  role   = aws_iam_role.node["loadgen"].id
  policy = data.aws_iam_policy_document.loadgen_ssm.json
}

resource "aws_iam_role_policy" "loadgen" {
  name   = "loadgen"
  role   = aws_iam_role.node["loadgen"].id
  policy = data.aws_iam_policy_document.loadgen.json
}

# --- Monitoring ------------------------------------------------------------

data "aws_iam_policy_document" "monitoring" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.monitoring.arn]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.perf.arn}/assets/*"]
  }
}

resource "aws_iam_role_policy" "monitoring" {
  name   = "monitoring"
  role   = aws_iam_role.node["monitoring"].id
  policy = data.aws_iam_policy_document.monitoring.json
}
