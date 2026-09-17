# A deliberately tiny module so example 02 can show `for_each` on a module call.
# Note what is NOT here: no for_each, no knowledge of how many copies exist.
# A module should describe ONE thing; the caller decides how many.

variable "name" {
  type = string
}

variable "owner" {
  type = string
}

resource "terraform_data" "bucket" {
  input = { name = var.name, owner = var.owner, versioning = true }
}

output "name" {
  value = var.name
}
