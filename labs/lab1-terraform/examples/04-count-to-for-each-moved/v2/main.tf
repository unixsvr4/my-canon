# -----------------------------------------------------------------------------
# v2 - the refactor: the same users, now keyed by name with for_each.
#
# Changing count -> for_each changes every ADDRESS:
#   terraform_data.user[0]  ->  terraform_data.user["alice"]
# Terraform treats a new address as a new resource. Without help, this refactor
# plans to destroy all three users and create three "new" ones. See moved.tf.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
}

variable "users" {
  type    = set(string)
  default = ["alice", "bob", "carol"]
}

resource "terraform_data" "user" {
  for_each = var.users

  input            = each.key
  triggers_replace = each.key
}
