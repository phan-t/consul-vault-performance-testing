# Roles for the load generators and monitoring. Each Vault cluster's role is
# in modules/vault-cluster. IAM is global; created through the East provider.

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
  roles       = toset(["loadgen", "monitoring"])
  init_arns   = [for k, v in local.vault : v.init_secret_arn]
  account_id  = data.aws_caller_identity.current.account_id
  region_list = [var.regions.east, var.regions.west]
}

resource "aws_iam_role" "node" {
  provider           = aws.east
  for_each           = local.roles
  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "node" {
  provider = aws.east
  for_each = local.roles
  name     = "${var.name}-${each.key}"
  role     = aws_iam_role.node[each.key].name
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  provider   = aws.east
  for_each   = local.roles
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "describe_instances" {
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "describe_instances" {
  provider = aws.east
  for_each = local.roles
  name     = "describe-instances"
  role     = aws_iam_role.node[each.key].id
  policy   = data.aws_iam_policy_document.describe_instances.json
}

# Load generators: read every cluster's init secret (root tokens, recovery
# key), and write one (the PR secondary's new root token after activation);
# perf assets and results; NLB target health; SSM Run Command on this
# project's instances in the sites' regions (link cuts, settling, starting load on
# loadgen-1).
data "aws_iam_policy_document" "loadgen" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = concat(local.init_arns, [aws_secretsmanager_secret.monitoring.arn])
  }

  statement {
    actions   = ["secretsmanager:PutSecretValue"]
    resources = local.init_arns
  }

  statement {
    actions   = ["elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth"]
    resources = ["*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.perf.arn]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.perf.arn}/assets/*", "${aws_s3_bucket.perf.arn}/results/*"]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.perf.arn}/results/*"]
  }

  statement {
    sid       = "RunShellOnProjectInstances"
    actions   = ["ssm:SendCommand"]
    resources = [for r in local.region_list : "arn:aws:ec2:${r}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.name]
    }
  }

  statement {
    sid       = "ShellDocument"
    actions   = ["ssm:SendCommand"]
    resources = [for r in local.region_list : "arn:aws:ssm:${r}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "CommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "loadgen" {
  provider = aws.east
  name     = "loadgen"
  role     = aws_iam_role.node["loadgen"].id
  policy   = data.aws_iam_policy_document.loadgen.json
}

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
  provider = aws.east
  name     = "monitoring"
  role     = aws_iam_role.node["monitoring"].id
  policy   = data.aws_iam_policy_document.monitoring.json
}
