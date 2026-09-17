# -----------------------------------------------------------------------------
# dev: small and cheap. Nothing public. Deletion protection explicitly OFF so the
# environment can be torn down and rebuilt at will - an opt-out you can see in
# review, rather than a default someone forgot to change.
# -----------------------------------------------------------------------------

tags = {
  Owner      = "platform"
  CostCenter = "infra-dev"
}

deletion_protection = false

# Each KEY becomes a resource address: module.app_stack.local_file.service["api"].
# Try it: delete the `web` line and plan - only web's resources are destroyed.
services = {
  api = { image = "api:1.4.2", cpu = 256, memory = 512, ports = [8080] }
  web = { image = "web:2.1.0", cpu = 256, memory = 512, ports = [8080] }
}
