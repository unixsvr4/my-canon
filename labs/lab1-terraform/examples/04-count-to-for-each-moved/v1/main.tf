# -----------------------------------------------------------------------------
# v1 - the legacy code: users managed with count over a list.
# This is what example 01 warns about, already deployed and holding real state.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
}

variable "users" {
  type    = list(string)
  default = ["alice", "bob", "carol"]
}

resource "terraform_data" "user" {
  count = length(var.users)

  input            = var.users[count.index]
  triggers_replace = var.users[count.index] # a ForceNew identity, like an IAM user name
}
