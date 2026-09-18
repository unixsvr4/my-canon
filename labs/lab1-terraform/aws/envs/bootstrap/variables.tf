variable "region" {
  description = "Region the state bucket lives in. Keep it the same for every root that shares this bucket."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the bucket, key alias and roles."
  type        = string
  default     = "canon"
}

variable "environment" {
  description = "Which environment's account this bootstrap is running in. Part of the bucket name, so dev and prod cannot collide."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "github_subjects" {
  description = "OIDC subjects allowed to assume the CI role. Pin the repository AND the ref; a bare repo:owner/name:* lets any branch or fork PR in."
  type        = list(string)
  default     = ["repo:unixsvr4/my-canon:ref:refs/heads/main"]

  validation {
    # A subject that does not start with repo: would match subjects from other
    # organisations entirely.
    condition     = alltrue([for s in var.github_subjects : startswith(s, "repo:")])
    error_message = "every github_subject must start with repo:<owner>/<name>."
  }

  validation {
    condition     = !contains(var.github_subjects, "*")
    error_message = "a bare * would let any repository on GitHub assume this role."
  }
}
