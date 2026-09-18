# -----------------------------------------------------------------------------
# envs/bootstrap/main.tf - the chicken-and-egg root.
#
# Terraform needs somewhere to keep state, and that somewhere has to be created
# before any other root can initialise. This root creates it, and it is the one
# root whose own state starts LOCAL and is then migrated into the bucket it just
# made (`terraform init -migrate-state` after uncommenting its backend).
#
# It also creates the identity CI uses, because the second bootstrap problem is
# credentials: a pipeline needs to authenticate to AWS without a secret stored
# anywhere. GitHub's OIDC provider solves it - the workflow presents a
# short-lived token, AWS exchanges it for a role session, and there is no access
# key to leak, rotate or find in a log.
#
# Run once per account, by a human, with elevated credentials:
#
#     terraform init && terraform apply
#
# Cost: the S3 bucket is pennies a month at this size; IAM and the OIDC provider
# are free; the CMK is 1 USD a month. Everything else in this directory is free.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # Uncomment AFTER the first apply, then run:
  #     terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket       = "canon-tfstate-dev"
  #   key          = "platform/bootstrap/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Repository = "my-canon"
      Root       = "aws/envs/bootstrap"
      ManagedBy  = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.name_prefix}-tfstate-${var.environment}"
}

# -----------------------------------------------------------------------------
# The state bucket.
#
# State is not a build artifact: it holds resource ids, and for some providers
# it holds secrets. It gets its own CMK, versioning, and a policy that refuses
# plaintext transport.
# -----------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "Terraform state for ${var.environment}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.name_prefix}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# WAIVER: trivy AVD-AWS-0089 wants S3 server access logging. For a state bucket
# the better control is CloudTrail S3 DATA EVENTS on this bucket: they record
# the IAM identity behind each GetObject/PutObject, which is the question you
# actually ask about state ("who wrote this?"), while server access logs are
# best-effort, delayed, and identity-poor. CloudTrail belongs to the audit
# account's root, not to this one.
#
#trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Deleting the state bucket deletes the record of everything Terraform
  # manages. This is one of the few places `prevent_destroy` earns its keep -
  # it only accepts a literal, and here a literal is exactly right.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  # The single most valuable setting on this bucket. A corrupted or
  # wrongly-edited state file becomes a restore of the previous version instead
  # of an afternoon of `terraform import`.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }

    # Without this, every GET and PUT is a separate KMS call. Terraform reads
    # and writes state constantly; bucket keys cut those calls (and the KMS
    # bill) by orders of magnitude.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning without a lifecycle rule grows forever. 90 days is long enough to
# recover from any mistake anyone notices.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# -----------------------------------------------------------------------------
# Keyless CI: GitHub Actions assumes a role via OIDC.
#
# This replaces an AWS access key stored as a repository secret. There is
# nothing to rotate and nothing to steal: the token is minted per job, lasts
# minutes, and is bound to this repository.
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub's certificate chain itself for this well-known issuer,
  # so the thumbprint is effectively vestigial - but the argument is still
  # required by the API, so it is set to the published value rather than left
  # to drift.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # THE CONDITION PEOPLE GET WRONG.
    #
    # Without a `sub` condition, ANY repository on GitHub - anyone's - can
    # assume this role. With `repo:owner/name:*`, any branch or pull request in
    # this repository can, which means a fork's PR workflow can too if the
    # workflow is configured to run it.
    #
    # Pinning to a ref (and, for the apply role, to `environment:prod`) is what
    # makes this safe: only a run on that branch, in that repository, gets
    # credentials.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in var.github_subjects : s]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${var.name_prefix}-terraform-plan"
  description          = "Read-only Terraform plan from CI (GitHub OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

# Plan needs to READ everything and write only the state lock. Splitting plan
# from apply is what lets a pull-request pipeline run on every push - including
# from a fork - without being able to change anything.
resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # s3:PutObject and s3:DeleteObject are needed even by a PLAN, because
  # use_lockfile writes and removes a .tflock object beside the state. This is
  # the permission people miss when moving off DynamoDB locking, and the error
  # ("Error acquiring the state lock") does not mention S3 permissions.
  statement {
    sid    = "ReadStateAndLock"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "UseStateKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "github_plan_state" {
  name   = "state-access"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

output "state_bucket" {
  description = "Bucket to put in every other root's backend block."
  value       = aws_s3_bucket.state.id
}

output "state_kms_alias" {
  description = "KMS alias for the backend's kms_key_id."
  value       = aws_kms_alias.state.name
}

output "github_plan_role_arn" {
  description = "Role the CI plan job assumes. Set it as a repository variable, not a secret - it is not sensitive."
  value       = aws_iam_role.github_plan.arn
}

output "backend_block" {
  description = "Paste this into the other roots' terraform{} block."
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.state.id}"
      key          = "platform/<root-name>/terraform.tfstate"
      region       = "${var.region}"
      encrypt      = true
      kms_key_id   = "${aws_kms_alias.state.name}"
      use_lockfile = true
    }
  EOT
}

output "account_id" {
  description = "Account this bootstrap ran in - worth printing, because running it in the wrong one is the classic mistake."
  value       = data.aws_caller_identity.current.account_id
}
