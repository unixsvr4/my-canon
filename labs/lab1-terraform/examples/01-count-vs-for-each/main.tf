# -----------------------------------------------------------------------------
# Example 01 - why for_each, not count, for anything with an identity.
#
# Both resources below manage the SAME three users. The only difference is how
# each instance is addressed:
#
#   count    -> terraform_data.by_index[0], [1], [2]        (a POSITION)
#   for_each -> terraform_data.by_name["alice"], ["bob"]... (a NAME)
#
# `triggers_replace` stands in for a ForceNew attribute on a real resource -
# an IAM user's name, a bucket name, a VM hostname. Change it and the resource
# must be destroyed and recreated. That is what makes the difference visible.
#
# Run ./demo.sh: remove "alice" from the front of the list and compare plans.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
}

variable "users" {
  description = "Users to manage. Order matters to count; it does not matter to for_each."
  type        = list(string)
  default     = ["alice", "bob", "carol"]
}

# count: instance [i] is "whatever is at position i of the list".
# Remove alice, and bob slides into [0], carol into [1], and [2] disappears.
resource "terraform_data" "by_index" {
  count = length(var.users)

  input            = var.users[count.index]
  triggers_replace = var.users[count.index]
}

# for_each: instance ["alice"] is alice, forever, wherever she is in the list.
# toset() because for_each accepts a map or a set of strings - not a list,
# precisely because a list's order would re-introduce positional identity.
resource "terraform_data" "by_name" {
  for_each = toset(var.users)

  input            = each.key
  triggers_replace = each.key
}

output "by_index" {
  value = { for i, r in terraform_data.by_index : i => r.output }
}

output "by_name" {
  value = { for k, r in terraform_data.by_name : k => r.output }
}
