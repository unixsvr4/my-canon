# -----------------------------------------------------------------------------
# Example 03 - nested for_each: firewall rules for service x port x CIDR.
#
# The real-world shape: a security group needs one rule per (service, port,
# source CIDR). The input is naturally nested; for_each needs one flat map.
#
# Two resources build the SAME rules with different keys:
#
#   terraform_data.rule             key = "api:443:10.0.0.0/8"   (derived from the data)
#   terraform_data.rule_positional  key = "rule-3"               (position in a flattened list)
#
# demo.sh removes one port and shows why the key is the whole design.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
}

variable "services" {
  type = map(object({
    ports = list(number)
    cidrs = list(string)
  }))
  default = {
    api = { ports = [443, 8443], cidrs = ["10.0.0.0/8", "192.168.0.0/16"] }
    web = { ports = [80, 443], cidrs = ["0.0.0.0/0"] }
  }
}

locals {
  # Step 1: expand. setproduct(ports, cidrs) yields every [port, cidr] pair -
  # a cleaner equivalent of two nested `for` loops. The outer `for` walks the
  # services; flatten() collapses the resulting list of lists.
  rules_list = flatten([
    for svc_name, svc in var.services : [
      for pair in setproduct(svc.ports, svc.cidrs) : {
        service = svc_name
        port    = pair[0]
        cidr    = pair[1]
      }
    ]
  ])

  # Step 2a: key by the DATA. Each key is the rule's identity; it survives any
  # reordering, insertion or removal elsewhere in the input.
  rules = { for r in local.rules_list : "${r.service}:${r.port}:${r.cidr}" => r }

  # Step 2b: key by POSITION. Looks harmless. It is count's re-indexing bug,
  # smuggled into for_each - for_each only protects you if the key is meaningful.
  rules_positional = { for i, r in local.rules_list : "rule-${i}" => r }
}

resource "terraform_data" "rule" {
  for_each = local.rules

  # triggers_replace mimics a real security-group rule: changing port or CIDR
  # is a delete + create, never an in-place update.
  triggers_replace = [each.value.port, each.value.cidr]
  input            = "allow ${each.value.cidr} -> ${each.value.service}:${each.value.port}"
}

resource "terraform_data" "rule_positional" {
  for_each = local.rules_positional

  triggers_replace = [each.value.port, each.value.cidr]
  input            = "allow ${each.value.cidr} -> ${each.value.service}:${each.value.port}"
}

output "rule_keys" {
  value = keys(local.rules)
}

# -----------------------------------------------------------------------------
# The same expansion on a real provider, where a resource has NESTED BLOCKS,
# uses a `dynamic` block instead of separate resources. Reference only - this
# example uses no cloud provider:
#
# resource "aws_security_group" "svc" {
#   for_each = var.services                       # one group per service
#   name     = "canon-${each.key}"
#
#   dynamic "ingress" {
#     for_each = setproduct(each.value.ports, each.value.cidrs)
#     content {
#       from_port   = ingress.value[0]
#       to_port     = ingress.value[0]
#       protocol    = "tcp"
#       cidr_blocks = [ingress.value[1]]
#     }
#   }
# }
#
# Trade-off: inline `dynamic` blocks replace the rule SET as one attribute, so
# any change rewrites the group's rules together. Separate rule resources (as
# above, aws_vpc_security_group_ingress_rule) give per-rule plans, per-rule
# drift, and per-rule blast radius - preferred when rules change often.
# -----------------------------------------------------------------------------
