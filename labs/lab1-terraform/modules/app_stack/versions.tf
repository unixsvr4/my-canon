# -----------------------------------------------------------------------------
# versions.tf - what this module needs, and nothing it doesn't own.
#
# A reusable module declares CONSTRAINTS only. It never contains a `provider`
# block: the caller (the environment root) configures providers - region,
# credentials, assume-role - which is exactly what lets the same module version
# run unchanged in dev, prod, or a different account.
#
# Constraint style:
#   required_version ">= 1.6.0"  - `terraform test`, `optional()` defaults, and
#                                   `import`/`moved` blocks are all relied on.
#   "~> 2.5"                     - any 2.x at or above 2.5, never 3.0. Minor
#                                   upgrades are allowed; majors are a decision.
# The exact provider build that ran is pinned by .terraform.lock.hcl in each
# environment root, which is committed - same instinct as a package lockfile.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    local  = { source = "hashicorp/local", version = "~> 2.5" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
