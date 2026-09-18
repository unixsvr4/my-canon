# -----------------------------------------------------------------------------
# versions.tf - constraints only. No `provider` block: the environment root
# configures region, credentials and assume-role, which is what lets one module
# version run unchanged in the dev account and the prod account.
#
#   required_version ">= 1.7.0"  - `mock_provider` in tests (1.7+) is how this
#                                  module is apply-tested without an AWS bill.
#   aws "~> 6.0"                 - any 6.x, never 7.0. Provider majors move
#                                  attributes and remove deprecated ones; that
#                                  is a scheduled change, not a `terraform init`.
#
# The exact provider build is pinned by .terraform.lock.hcl in each environment
# root, committed, same instinct as a package lockfile.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
