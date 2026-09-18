# -----------------------------------------------------------------------------
# iam.tf - two kinds of role, and the difference matters.
#
#   execution role  - used by the ECS AGENT, before the container starts: pull
#                     the image, fetch the secret, create the log stream.
#   task role       - used by the APPLICATION, at runtime: whatever that service
#                     itself is allowed to call.
#
# Putting the application's permissions on the execution role is the most common
# ECS mistake. It works, which is why it survives review - and it means every
# container on the cluster inherits the union of every service's permissions.
#
# The execution role is shared (its permissions are identical for every
# service). The task roles are PER SERVICE, via for_each, because that is the
# boundary that has to hold: a compromise of `web` must not be able to read
# `api`'s data.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name                 = "${var.name_prefix}-ecs-execution"
  description          = "ECS agent: image pull, secret fetch, log stream creation"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  max_session_duration = 3600

  # A permissions boundary is the control that survives a mistake in a policy
  # attached later: it caps what this role can EVER be granted, including by
  # someone with iam:PutRolePolicy. Set it in the roots that have one.
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-ecs-execution" })
}

data "aws_iam_policy_document" "execution" {
  # ecr:GetAuthorizationToken is an account-level call: it takes no resource, so
  # the ARN must be "*". This is the exception, not the pattern - and it is
  # worth writing down why, because "the scanner told me to scope it" wastes an
  # afternoon otherwise.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPull"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]

    resources = ["${local.arn_prefix}:ecr:${local.region}:${local.account_id}:repository/*"]
  }

  # Scoped to THIS stack's log groups. The managed
  # AmazonECSTaskExecutionRolePolicy grants logs:* on "*", which is why this
  # module writes its own policy instead of attaching the managed one.
  statement {
    sid    = "Logs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      for key in keys(var.services) :
      "${aws_cloudwatch_log_group.service[key].arn}:*"
    ]
  }

  statement {
    sid       = "DatabaseSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }

  # Decrypting the secret and writing encrypted logs both go through the CMK.
  statement {
    sid       = "Kms"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.this.arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.name_prefix}-ecs-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# --- One task role per service ------------------------------------------------
resource "aws_iam_role" "task" {
  for_each = var.services

  name                 = "${var.name_prefix}-${each.key}-task"
  description          = "Runtime identity for the ${each.key} service"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  max_session_duration = 3600
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}-task", Service = each.key })
}

# The runtime policy: only what the application itself needs.
#
# ssmmessages:* on "*" is what `aws ecs execute-command` requires - the
# resource is the SSM data channel, which has no ARN until the session exists.
# It is granted here rather than on the execution role so that turning
# execute-command off for one service is a one-line change.
data "aws_iam_policy_document" "task" {
  for_each = var.services

  statement {
    sid    = "OwnLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.service[each.key].arn}:*"]
  }

  statement {
    sid    = "ExecuteCommandChannel"
    effect = "Allow"

    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]

    resources = ["*"]
  }

  # IAM database authentication: a 15-minute token instead of a password, and
  # the db user name is pinned to this service, so `web`'s role cannot connect
  # as `api`.
  statement {
    sid       = "DatabaseIamAuth"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["${local.arn_prefix}:rds-db:${local.region}:${local.account_id}:dbuser:${aws_db_instance.this.resource_id}/${each.key}"]
  }
}

resource "aws_iam_role_policy" "task" {
  for_each = var.services

  name   = "${var.name_prefix}-${each.key}-task"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task[each.key].json
}
