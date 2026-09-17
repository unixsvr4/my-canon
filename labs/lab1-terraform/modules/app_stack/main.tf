# -----------------------------------------------------------------------------
# main.tf - app_stack: a service stack, modelled with $0 local resources.
#
# Each local_file here stands in for a real cloud resource, so the lab runs
# offline and free while the STRUCTURE is exactly what you would write for AWS:
#
#   local_file.service          -> aws_ecs_service / aws_ecs_task_definition
#   local_file.listener         -> aws_lb_listener  (one per service x port)
#   local_file.public_endpoint  -> aws_route53_record + aws_lb_target_group
#   local_file.runbook          -> aws_cloudwatch_dashboard (one per service)
#   local_file.stateful_store   -> aws_db_instance  (a singleton, no for_each)
#
# The file is organised as a tour of for_each, simplest first:
#   A. for_each over a map of objects          (local_file.service)
#   B. for_each over a FLATTENED nested map    (local_file.listener)
#   C. for_each over a FILTERED map            (local_file.public_endpoint)
#   D. for_each over ANOTHER RESOURCE          (local_file.runbook)
#   E. no for_each at all, and why             (local_file.stateful_store)
# -----------------------------------------------------------------------------

locals {
  # Tag contract. Module-owned keys are applied first, then caller tags, so a
  # caller can ADD tags (Owner, CostCenter) but the module always stamps
  # Environment/ManagedBy/Module - which is what cost reports and audits key on.
  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "app_stack"
    },
    var.tags,
  )

  # path.root = the directory Terraform was run from (the environment root), so
  # dev and prod write to separate places even though they share this module.
  artifact_dir = "${path.root}/.artifacts"

  # --- for B: flatten a nested structure into a map with a composite key -----
  #
  # for_each needs ONE flat map (or set). Services contain lists of ports, so:
  #   1. the inner `for` produces a list of listener objects per service,
  #   2. flatten() turns the list-of-lists into one list,
  #   3. the outer `for` turns that list into a map keyed "service-port".
  #
  # Input:   { api = { ports = [443, 8443] }, web = { ports = [443] } }
  # Result:  { "api-443"  = { service = "api", port = 443,  ... },
  #            "api-8443" = { service = "api", port = 8443, ... },
  #            "web-443"  = { service = "web", port = 443,  ... } }
  #
  # The composite key is the design decision that matters: it must be STABLE
  # and UNIQUE. Removing port 8443 from api destroys exactly "api-8443" and
  # nothing else. (Uniqueness is enforced by a validation in variables.tf -
  # a duplicate key here would be a hard error: "Duplicate object key".)
  listeners = {
    for l in flatten([
      for svc_name, svc in var.services : [
        for port in svc.ports : {
          key     = "${svc_name}-${port}"
          service = svc_name
          port    = port
          public  = svc.public
        }
      ]
    ]) : l.key => l
  }

  # --- for C: filter a map with an `if` clause --------------------------------
  #
  # Only services marked public get an endpoint. This is the idiomatic way to
  # make a resource conditional PER KEY. (The whole-resource version of the
  # same idea is `for_each = var.enabled ? var.things : {}`.)
  public_services = { for name, svc in var.services : name => svc if svc.public }
}

# -----------------------------------------------------------------------------
# One deploy id PER SERVICE, rotated only when that service's image changes.
#
# Lesson learned the hard way (see RESEARCH.md): an earlier version had ONE
# deploy id for the whole stack, with keepers = the set of service names. Every
# service embedded it, so removing `web` changed the id and REPLACED `api` too.
# A single shared dependency silently re-coupled instances that for_each had
# isolated. Keying the dependency the same way as its consumers fixes it.
# -----------------------------------------------------------------------------
resource "random_id" "deploy" {
  for_each = var.services

  byte_length = 4

  keepers = {
    image = each.value.image
  }
}

# -----------------------------------------------------------------------------
# A. for_each over a map of objects
#
#   each.key   -> the map key ("api")
#   each.value -> that service's object ({ image, cpu, memory, ... })
#   address    -> module.app_stack.local_file.service["api"]
# -----------------------------------------------------------------------------
resource "local_file" "service" {
  for_each = var.services

  filename        = "${local.artifact_dir}/${var.name_prefix}-${each.key}.json"
  file_permission = "0644"

  content = jsonencode({
    name          = "${var.name_prefix}-${each.key}"
    environment   = var.environment
    image         = each.value.image
    cpu           = each.value.cpu
    memory        = each.value.memory
    desired_count = each.value.desired_count
    public        = each.value.public
    deploy_id     = random_id.deploy[each.key].hex # same key -> no cross-service coupling
    tags          = local.common_tags
  })

  lifecycle {
    # Preconditions fail in PLAN, per key, with a readable message - in the PR,
    # not twenty minutes into an apply as a provider API error.
    precondition {
      condition     = each.value.memory >= each.value.cpu * 2
      error_message = "Service ${each.key}: memory (${each.value.memory}) must be at least 2x cpu (${each.value.cpu})."
    }
    precondition {
      condition     = var.environment != "prod" || each.value.desired_count >= 2
      error_message = "Service ${each.key}: prod requires desired_count >= 2 so one instance can fail."
    }
  }
}

# -----------------------------------------------------------------------------
# B. for_each over a flattened nested structure (see local.listeners)
#
#   address -> module.app_stack.local_file.listener["api-443"]
# -----------------------------------------------------------------------------
resource "local_file" "listener" {
  for_each = local.listeners

  filename        = "${local.artifact_dir}/listeners/${var.name_prefix}-${each.key}.json"
  file_permission = "0644"

  content = jsonencode({
    name     = "${var.name_prefix}-${each.key}"
    service  = each.value.service
    port     = each.value.port
    protocol = each.value.port == 443 || each.value.port == 8443 ? "HTTPS" : "HTTP"
    scheme   = each.value.public ? "internet-facing" : "internal"

    # Cross-resource reference INTO a for_each resource: index it by key.
    # This is how a listener finds "its" service without positional coupling.
    target = local_file.service[each.value.service].filename
    tags   = local.common_tags
  })
}

# -----------------------------------------------------------------------------
# C. for_each over a filtered map (see local.public_services)
#
# In dev, where nothing is public, this resource has ZERO instances - no count
# ternaries, no special cases, the map is simply empty.
# -----------------------------------------------------------------------------
resource "local_file" "public_endpoint" {
  for_each = local.public_services

  filename        = "${local.artifact_dir}/endpoints/${var.name_prefix}-${each.key}.json"
  file_permission = "0644"

  content = jsonencode({
    fqdn    = "${each.key}.${var.environment}.canon.example"
    service = "${var.name_prefix}-${each.key}"
    ports   = each.value.ports
    tags    = local.common_tags
  })

  lifecycle {
    precondition {
      condition     = length(each.value.ports) > 0
      error_message = "Service ${each.key} is public but has no ports - there is nothing to expose."
    }
  }
}

# -----------------------------------------------------------------------------
# D. for_each over another resource
#
# `for_each = local_file.service` iterates that resource's INSTANCES. The keys
# are the same service names, and each.value is the whole resource object, so
# attributes computed at apply time (filename, content hash) are available.
# Adding a service automatically adds its runbook; nobody keeps two lists in
# sync by hand.
# -----------------------------------------------------------------------------
resource "local_file" "runbook" {
  for_each = local_file.service

  filename        = "${local.artifact_dir}/runbooks/${var.name_prefix}-${each.key}.md"
  file_permission = "0644"

  content = <<-EOT
    # Runbook: ${jsondecode(each.value.content).name}

    - Environment: ${var.environment}
    - Image: ${jsondecode(each.value.content).image}
    - Replicas: ${jsondecode(each.value.content).desired_count}
    - Definition: ${each.value.filename}
    - Listeners: ${join(", ", [for k, l in local.listeners : tostring(l.port) if l.service == each.key])}
  EOT
}

# -----------------------------------------------------------------------------
# E. No for_each, on purpose.
#
# A datastore is a singleton with its own lifecycle. Folding it into the
# services map would put stateful data one tfvars typo away from a destroy.
#
# In the real module this is an aws_db_instance with `prevent_destroy = true`.
# prevent_destroy only accepts a literal, not a variable, so the production
# pattern is: stateful resources live in their own root, with their own apply
# approval - a stronger control than a lifecycle flag anyway.
# -----------------------------------------------------------------------------
resource "local_file" "stateful_store" {
  filename        = "${local.artifact_dir}/${var.name_prefix}-datastore.json"
  file_permission = "0644"

  content = jsonencode({
    name                = "${var.name_prefix}-datastore"
    environment         = var.environment
    deletion_protection = var.deletion_protection
    tags                = local.common_tags
  })

  # Deliberately NO create_before_destroy. This object has a FIXED identity (its
  # name). An earlier version set create_before_destroy = true, and
  # `terraform apply -replace` on it created the new file, then destroyed the old
  # one - at the same path - leaving nothing on disk while state and the apply
  # both reported success. verify-env.py caught it (see RESEARCH.md, T11); the
  # integration test's replace_datastore run guards it now. On AWS the same
  # mistake fails as "DBInstanceAlreadyExists". create_before_destroy is only
  # safe when the replacement gets a new name (name_prefix, random suffix).
}
