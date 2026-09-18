# -----------------------------------------------------------------------------
# envs/prod/main.tf - the same module, a different account, different inputs.
#
# Read this next to ../dev/main.tf. The module call is identical in shape; only
# data differs. That is what makes "prod behaves like dev" true by
# construction rather than by hope - and it is why the differences that DO
# exist (deletion protection, retention, instance class, the pinned module
# version) are visible in one diff.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # backend "s3" {
  #   bucket       = "canon-tfstate-prod"   # a DIFFERENT AWS account from dev
  #   key          = "platform/app-stack/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   kms_key_id   = "alias/canon-tfstate"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Repository = "my-canon"
      Root       = "aws/envs/prod"
    }
  }

  # assume_role {
  #   role_arn     = "arn:aws:iam::444455556666:role/canon-terraform-prod"
  #   session_name = "terraform-prod"
  # }
}

module "app_stack" {
  # In production, prod points at a TAG, not at a branch or a local path:
  #   source = "git::https://github.com/canon/terraform-modules.git//app_stack?ref=v1.4.0"
  # Promotion is bumping that ref here, after the same version has run in dev.
  source = "../../modules/app_stack"

  name_prefix = "canon-prod"
  environment = "prod"

  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  public_subnet_ids  = var.public_subnet_ids
  certificate_arn    = var.certificate_arn
  hosted_zone_id     = var.hosted_zone_id
  domain             = var.domain
  access_logs_bucket = var.access_logs_bucket

  services = var.services
  tags     = var.tags

  # Left at the module default (true) deliberately - and the module's own
  # precondition refuses prod with it off, so this cannot be "temporarily"
  # disabled in a hurry without the plan failing and saying why.

  # Prod pays for what prod needs: a year of logs, a database that can take a
  # Multi-AZ failover, and an SNS topic that actually pages someone.
  log_retention_days       = 365
  db_instance_class        = "db.t4g.medium"
  db_allocated_storage     = 100
  alarm_topic_arn          = var.alarm_topic_arn
  permissions_boundary_arn = var.permissions_boundary_arn

  # Narrower than the module default of 0.0.0.0/0: prod sits behind CloudFront,
  # so only CloudFront's ranges should reach the ALB directly. In a real root
  # this is the `com.amazonaws.global.cloudfront.origin-facing` managed prefix
  # list; the CIDR form is here because a prefix list id is account-specific.
  public_ingress_cidrs = var.public_ingress_cidrs
}

output "service_names" {
  description = "Service key => ECS service name."
  value       = module.app_stack.service_names
}

output "listeners" {
  description = "Listener key (service-port) => port."
  value       = module.app_stack.listeners
}

output "public_endpoints" {
  description = "Public service => FQDN."
  value       = module.app_stack.public_endpoints
}

output "cluster_name" {
  description = "ECS cluster name, for `aws ecs execute-command`."
  value       = module.app_stack.cluster_name
}

output "task_definition_digests" {
  description = "Service => digest of its rendered task definition."
  value       = module.app_stack.task_definition_digests
}
