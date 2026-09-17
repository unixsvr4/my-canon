# -----------------------------------------------------------------------------
# prod: same module, same version, different inputs.
#
# Guard rails the module enforces here (see modules/app_stack/main.tf):
#   - desired_count >= 2 for every service  (precondition, fails at plan)
#   - public services must expose a port     (precondition, fails at plan)
#   - explicit image tags, never :latest     (variable validation)
# -----------------------------------------------------------------------------

tags = {
  Owner      = "platform"
  CostCenter = "infra-prod"
  Compliance = "soc2"
}

deletion_protection = true

services = {
  # Public: gets listeners on 443 and 8443 AND a public endpoint (filtered for_each).
  api = { image = "api:1.4.2", cpu = 512, memory = 2048, desired_count = 3, public = true, ports = [443, 8443] }

  # Public on 443 only.
  web = { image = "web:2.1.0", cpu = 512, memory = 1024, desired_count = 2, public = true, ports = [443] }

  # Internal worker: no ports, so it gets NO listener and NO endpoint - the
  # flattened and filtered maps simply have no entries for it.
  worker = { image = "worker:0.9.1", cpu = 256, memory = 1024, desired_count = 2 }
}
