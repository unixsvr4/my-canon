# -----------------------------------------------------------------------------
# outputs.tf - the module's public interface.
#
# Callers depend on outputs, not on internal resource addresses, so internals
# can be refactored (with `moved` blocks) without breaking anyone. Keep outputs
# small, stable, and shaped as MAPS keyed like the input - a list output from a
# for_each resource has an order nobody should rely on.
# -----------------------------------------------------------------------------

output "service_names" {
  description = "Service key => fully-qualified service name."
  value       = { for key, f in local_file.service : key => jsondecode(f.content).name }
}

output "listeners" {
  description = "Listener key (service-port) => port. Shows the flattened composite keys."
  value       = { for key, l in local.listeners : key => l.port }
}

output "public_endpoints" {
  description = "Public service => FQDN. Empty map when nothing is public."
  value       = { for key, f in local_file.public_endpoint : key => jsondecode(f.content).fqdn }
}

output "deploy_ids" {
  description = "Service => deploy id. Rotates only when that service's image changes."
  value       = { for key, id in random_id.deploy : key => id.hex }
}

output "artifact_dir" {
  description = "Where the rendered stand-in resources are written."
  value       = local.artifact_dir
}
