# -----------------------------------------------------------------------------
# Example 02 - every input shape for_each accepts, and how to convert to one.
#
# for_each takes exactly two things: a MAP, or a SET OF STRINGS. Everything
# else (lists, lists of objects, nested structures) has to be converted, and
# the conversion is where the real design decision lives: what is the KEY?
#
#   A. set of strings            toset(list)                      each.key == each.value
#   B. map of objects            direct                           each.value.<attr>
#   C. list of objects -> map    { for x in list : x.name => x }  pick the identity attribute
#   D. filtered map              { for k, v in m : k => v if ... } conditional per key
#   E. another resource          for_each = terraform_data.b       chain; keys follow
#   F. a module                  module "x" { for_each = ... }     whole module per key
#   G. keys unknown until apply  for_each = toset([resource.id])   the error you must design around
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
}

# --- A. set of strings --------------------------------------------------------
variable "regions" {
  type    = list(string)
  default = ["us-east-1", "eu-west-1", "us-east-1"] # duplicate on purpose
}

# toset() also DE-DUPLICATES: us-east-1 appears once. With a set, each.key and
# each.value are the same string.
resource "terraform_data" "region" {
  for_each = toset(var.regions)
  input    = "log bucket in ${each.key}"
}

# --- B. map of objects ----------------------------------------------------------
variable "teams" {
  type = map(object({
    owner  = string
    budget = number
  }))
  default = {
    payments = { owner = "alice", budget = 5000 }
    risk     = { owner = "bob", budget = 3000 }
  }
}

resource "terraform_data" "team" {
  for_each = var.teams
  input    = "${each.key} owned by ${each.value.owner}, budget ${each.value.budget}"
}

# --- C. list of objects -> map keyed by an identity attribute ------------------
#
# APIs and YAML files hand you lists. Convert with a `for` expression and choose
# the attribute that IS the identity - never the list index.
variable "hosts" {
  type = list(object({
    hostname = string
    rack     = string
    role     = string
  }))
  default = [
    { hostname = "gw01", rack = "R14", role = "gateway" },
    { hostname = "gw02", rack = "R14", role = "gateway" },
    { hostname = "db01", rack = "R15", role = "database" },
  ]
}

locals {
  # If two entries shared a hostname this would fail with "Duplicate object key"
  # - which is correct: two hosts with one identity is a data error. (Appending
  # `...` groups duplicates into lists instead, when that is what you mean.)
  hosts_by_name = { for h in var.hosts : h.hostname => h }

  # Grouping with `...`: role => [hostnames]. Useful for inventories.
  hostnames_by_role = { for h in var.hosts : h.role => h.hostname... }
}

resource "terraform_data" "host" {
  for_each = local.hosts_by_name
  input    = "${each.key} in rack ${each.value.rack} as ${each.value.role}"
}

# --- D. filtered map: a resource only for SOME keys ----------------------------
resource "terraform_data" "db_backup" {
  for_each = { for name, h in local.hosts_by_name : name => h if h.role == "database" }
  input    = "nightly backup for ${each.key}"
}

# --- E. for_each over another resource ------------------------------------------
#
# each.value is the upstream resource OBJECT, so apply-time attributes (id,
# output) are usable. The KEYS must still be known at plan time - they are,
# because they come from local.hosts_by_name, not from anything computed.
resource "terraform_data" "host_monitor" {
  for_each = terraform_data.host
  input    = "monitor for ${each.key} (tracks ${each.value.id})"
}

# --- F. for_each on a module -----------------------------------------------------
#
# The whole module is instantiated once per key:
#   module.bucket["payments"].terraform_data.bucket
module "bucket" {
  source   = "./modules/bucket"
  for_each = var.teams

  name  = "canon-${each.key}-artifacts"
  owner = each.value.owner
}

# --- G. keys that are unknown until apply --------------------------------------
#
# for_each keys become resource ADDRESSES, so Terraform must know them at plan.
# A key derived from an apply-time value (an id, a generated name) fails with
#   "Invalid for_each argument ... cannot be determined until apply".
# Off by default; demo.sh turns it on against empty state to show the error.
# The fix is always the same: key on something you already know (a name from
# config), and put the computed value in each.value instead.
variable "demo_unknown_keys" {
  type    = bool
  default = false
}

resource "terraform_data" "seed" {
  input = "created at apply time"
}

resource "terraform_data" "unknown_key" {
  for_each = var.demo_unknown_keys ? toset([terraform_data.seed.id]) : toset([])
  input    = each.key
}

# --- outputs: shape them as maps, keyed like the input -------------------------
output "regions" {
  value = keys(terraform_data.region)
}

output "hostnames_by_role" {
  value = local.hostnames_by_role
}

output "backups" {
  value = keys(terraform_data.db_backup)
}

output "buckets" {
  value = { for team, m in module.bucket : team => m.name }
}
