# -----------------------------------------------------------------------------
# data.tf - context the module reads from the provider, and the policy documents
# that several files reference.
#
# aws_partition, not a hard-coded "aws": ARNs differ in GovCloud (aws-us-gov)
# and China (aws-cn). Writing "arn:aws:..." is the single most common reason a
# module cannot be used in a regulated account without editing it.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  arn_prefix = "arn:${data.aws_partition.current.partition}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # compact() over one optional ARN: with no topic configured the alarms still
  # exist and still go into ALARM state, they just notify nothing. An alarm
  # with no action is a dashboard; an alarm with an action is an on-call page.
  alarm_actions = compact([var.alarm_topic_arn])

  # ALB target-group names are capped at 32 characters, and name_prefix (which
  # create_before_destroy forces - see alb.tf) is capped at SIX. Derived once,
  # here, so the cap is visible in one place instead of inline in a resource.
  tg_prefix = {
    for key in keys(var.services) :
    key => substr(replace(key, "/[^a-z0-9]/", ""), 0, min(6, length(replace(key, "/[^a-z0-9]/", ""))))
  }
}

# -----------------------------------------------------------------------------
# The KMS key policy.
#
# A key policy is not optional extra hardening: a CMK with no policy is usable
# by nobody, including the account that owns it. Two statements are needed -
# the account's own administrative access, and the CloudWatch Logs service
# principal, which encrypts on the caller's behalf and therefore needs its own
# grant, scoped with a condition to log groups in THIS account.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "kms" {
  statement {
    sid     = "AccountAdministration"
    effect  = "Allow"
    actions = ["kms:*"]

    principals {
      type        = "AWS"
      identifiers = ["${local.arn_prefix}:iam::${local.account_id}:root"]
    }

    resources = ["*"] # a key policy's resource is always the key it is attached to
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"

    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["${local.arn_prefix}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
}

# Both ECS roles are assumed by the ECS agent, not by a human.
#
# The two conditions are the confused-deputy guard: without them, any principal
# that can call sts:AssumeRole through the ECS service in ANY account could use
# this role. aws:SourceAccount and aws:SourceArn pin it to this account's tasks.
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["${local.arn_prefix}:ecs:${local.region}:${local.account_id}:*"]
    }
  }
}
