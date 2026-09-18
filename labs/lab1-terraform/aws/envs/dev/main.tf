# -----------------------------------------------------------------------------
# envs/dev/main.tf - a THIN environment root.
#
# A root has exactly three jobs: where state lives (backend), how the provider
# is configured (region, identity, default tags), and which INPUTS this
# environment passes to the shared module. No resource logic lives here.
#
# Directory per environment, not workspaces, and one AWS ACCOUNT per
# environment. Workspaces share a backend and a set of credentials, so "I was
# in the wrong workspace" is a production incident waiting for a tired
# afternoon. With separate roots and separate accounts, a mistake in dev
# physically cannot reach prod: the credentials do not exist there.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # Uncomment once envs/bootstrap has created the bucket in this account.
  # Left commented so the repository can be cloned, initialised and validated
  # with no AWS account at all.
  #
  # backend "s3" {
  #   bucket       = "canon-tfstate-dev"
  #   key          = "platform/app-stack/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   kms_key_id   = "alias/canon-tfstate"
  #   use_lockfile = true   # S3-native locking (Terraform 1.10+); replaces dynamodb_table
  # }
  #
  # One key per root, never one state file for everything: state is the unit of
  # locking and of blast radius. Bucket versioning is on, so a corrupted state
  # is a restore rather than a rebuild.
}

provider "aws" {
  region = var.region

  # default_tags applies these to every resource this provider creates,
  # including resources inside modules that forgot to tag something. The module
  # still sets its own tags - defence in depth, because default_tags is a
  # property of the CALLER and a module must be correct on its own.
  default_tags {
    tags = {
      Repository = "my-canon"
      Root       = "aws/envs/dev"
    }
  }

  # In CI this is empty and the identity comes from the OIDC role assumed by the
  # workflow (see envs/bootstrap). Locally it is a named profile. Either way
  # there are no long-lived access keys in the repository or on the runner.
  #
  # assume_role {
  #   role_arn     = "arn:aws:iam::111122223333:role/canon-terraform-dev"
  #   session_name = "terraform-dev"
  # }
}

module "app_stack" {
  # In production this is a pinned, versioned source:
  #   source = "git::https://github.com/canon/terraform-modules.git//app_stack?ref=v1.4.0"
  # Promotion from dev to prod is a one-line bump of that ref in envs/prod,
  # after the version has soaked here.
  source = "../../modules/app_stack"

  name_prefix = "canon-dev"
  environment = "dev"

  # Network, certificate and log bucket come from the platform roots. In a real
  # repository these are `terraform_remote_state` data sources or SSM parameters
  # written by those roots; they are variables here so this root can be
  # validated and tested with no account.
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  public_subnet_ids  = var.public_subnet_ids
  certificate_arn    = var.certificate_arn
  hosted_zone_id     = var.hosted_zone_id
  domain             = var.domain
  access_logs_bucket = var.access_logs_bucket

  services = var.services
  tags     = var.tags

  # dev opts OUT of the safe default, explicitly, in the environment that can
  # afford it. The module defaults to protected; nothing is protected by
  # accident and nothing is unprotected by accident either.
  deletion_protection = false

  # Cheap in dev: 14 days of logs, the smallest database, single-AZ (the module
  # ties Multi-AZ to environment == "prod").
  log_retention_days = 14
  db_instance_class  = "db.t4g.micro"
}

# Re-export the module's interface so `terraform output` in this root is useful
# to the next root and to deploy tooling.
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
  description = "Service => digest of its rendered task definition. Lets CI tell which services a commit actually changed."
  value       = module.app_stack.task_definition_digests
}
