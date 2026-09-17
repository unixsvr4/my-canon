# -----------------------------------------------------------------------------
# envs/prod/main.tf - a THIN environment root.
#
# A root has exactly three jobs: where state lives (backend), how providers are
# configured, and which INPUTS this environment passes to the shared module.
# There is no resource logic here. dev and prod call the same module with
# different tfvars, so "prod behaves like dev" is true by construction.
#
# Directory-per-environment, not workspaces: each environment has its own state
# file, its own credentials, its own CI job and approval gate - a mistake in dev
# physically cannot plan against prod.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # Local state keeps the lab at $0. The production backend for this root:
  #
  # backend "s3" {
  #   bucket       = "canon-tfstate-prod"                  # prod state bucket - different AWS account from dev
  #   key          = "platform/app-stack/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true                                 # SSE-KMS with a dedicated key
  #   kms_key_id   = "alias/canon-tfstate-prod"
  #   use_lockfile = true                                 # S3-native locking (1.10+); replaces dynamodb_table
  # }
  #
  # Bucket versioning is ON, so a corrupted or wrongly-edited state is a restore,
  # not a rebuild.
}

module "app_stack" {
  # In production this is a pinned, versioned source, e.g.
  #   source = "git::https://github.com/canon/terraform-modules.git//app_stack?ref=v1.4.0"
  # Promotion from dev to prod = bump this ref in envs/prod after it has soaked.
  source = "../../modules/app_stack"

  name_prefix         = "canon-prod"
  environment         = "prod"
  tags                = var.tags
  services            = var.services
  deletion_protection = var.deletion_protection
}

# Re-export the module's interface so `terraform output` in this root is useful.
output "service_names" {
  value = module.app_stack.service_names
}

output "listeners" {
  value = module.app_stack.listeners
}

output "public_endpoints" {
  value = module.app_stack.public_endpoints
}
