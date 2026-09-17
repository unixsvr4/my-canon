# -----------------------------------------------------------------------------
# Integration tests: `command = apply`. These CREATE real resources, inspect
# what was actually built, then terraform test destroys everything it created
# (in reverse run order) when the file finishes.
#
# app_stack.tftest.hcl proves the PLAN is right. This file proves the RESULT is
# right: the objects exist, their contents match the inputs, the references
# between them resolve, and a change to one service leaves the others alone -
# checked against applied values that don't exist at plan time.
#
# The runs share state and execute in order, so each one is a lifecycle step:
#   1. create     -> everything exists, readable, wired together
#   2. update api -> only api's deploy id rotates; web is untouched
#   3. remove web -> web's objects are gone from disk; api still intact
#
# In AWS these assertions would read back through data sources
# (aws_ecs_service, aws_lb_listener) or a `check` block with an http probe;
# here file() reads the stand-in objects straight off disk.
# -----------------------------------------------------------------------------

variables {
  name_prefix = "canon-itest"
  environment = "prod"
  tags        = { Owner = "platform", CostCenter = "itest" }
  services = {
    api = { image = "api:1.4.2", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
    web = { image = "web:2.1.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443] }
  }
}

# --- 1. create: everything exists, is readable, and is wired together --------
run "create" {
  command = apply

  # Every object Terraform says it created is really there.
  assert {
    condition = alltrue([
      for f in concat(values(local_file.service), values(local_file.listener), values(local_file.public_endpoint),
      values(local_file.runbook), [local_file.stateful_store]) : fileexists(f.filename)
    ])
    error_message = "a resource in state has no object on disk"
  }

  # What was built matches what was asked for (read back, not taken from state).
  assert {
    condition = alltrue([
      for k, svc in var.services :
      jsondecode(file(local_file.service[k].filename)).image == svc.image &&
      jsondecode(file(local_file.service[k].filename)).desired_count == svc.desired_count
    ])
    error_message = "a service definition on disk does not match its input"
  }

  # The applied deploy id is embedded in the service it belongs to - an
  # apply-time value a plan-only test cannot see.
  assert {
    condition = alltrue([
      for k, id in random_id.deploy : jsondecode(file(local_file.service[k].filename)).deploy_id == id.hex
    ])
    error_message = "a service does not carry its own deploy id"
  }

  # References resolve: every listener targets a service object that exists.
  assert {
    condition = alltrue([
      for l in local_file.listener : fileexists(jsondecode(file(l.filename)).target)
    ])
    error_message = "a listener targets a service definition that does not exist"
  }

  # Public listeners are TLS; a public endpoint exposes exactly its listeners' ports.
  assert {
    condition = alltrue([
      for l in local_file.listener : jsondecode(file(l.filename)).protocol == "HTTPS"
      if jsondecode(file(l.filename)).scheme == "internet-facing"
    ])
    error_message = "an internet-facing listener is not HTTPS"
  }

  assert {
    condition     = jsondecode(file(local_file.public_endpoint["api"].filename)).ports == [443, 8443]
    error_message = "api's endpoint should expose exactly 443 and 8443"
  }

  # The mandatory tag contract is stamped on the real object.
  assert {
    condition = alltrue([
      for tag in ["Environment", "ManagedBy", "Module", "Owner", "CostCenter"] :
      contains(keys(jsondecode(file(local_file.stateful_store.filename)).tags), tag)
    ])
    error_message = "the datastore is missing a mandatory tag"
  }

  assert {
    condition     = jsondecode(file(local_file.stateful_store.filename)).deletion_protection == true
    error_message = "deletion protection must default to on"
  }

  # The runbook was generated from the applied service, not from a second list.
  assert {
    condition     = strcontains(file(local_file.runbook["api"].filename), "Listeners: 443, 8443")
    error_message = "api's runbook does not list its listeners"
  }
}

# --- 2. update one service: the others must not move -------------------------
run "update_api_image" {
  command = apply

  variables {
    services = {
      api = { image = "api:1.5.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
      web = { image = "web:2.1.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443] }
    }
  }

  assert {
    condition     = output.deploy_ids["api"] != run.create.deploy_ids["api"]
    error_message = "api's image changed, so its deploy id must rotate"
  }

  assert {
    condition     = output.deploy_ids["web"] == run.create.deploy_ids["web"]
    error_message = "web was not changed, so its deploy id must not rotate (cross-service coupling)"
  }

  assert {
    condition     = jsondecode(file(local_file.service["api"].filename)).image == "api:1.5.0"
    error_message = "the new api image did not reach the object on disk"
  }
}

# --- 3. remove a service: its objects are really gone, the rest stay ----------
run "remove_web" {
  command = apply

  variables {
    services = {
      api = { image = "api:1.5.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
    }
  }

  assert {
    condition = !anytrue([
      for p in ["canon-itest-web.json", "listeners/canon-itest-web-443.json", "endpoints/canon-itest-web.json", "runbooks/canon-itest-web.md"] :
      fileexists("${output.artifact_dir}/${p}")
    ])
    error_message = "removing web from the map must delete web's objects, not orphan them"
  }

  assert {
    condition     = output.deploy_ids["api"] == run.update_api_image.deploy_ids["api"]
    error_message = "removing web must not touch api"
  }
}

# --- 4. replace a fixed-name object: it must still exist afterwards ------------
# Regression: with create_before_destroy on the datastore, `-replace` created the
# new object and then destroyed the old one AT THE SAME NAME, leaving nothing -
# while the apply and the state both reported success.
run "replace_datastore" {
  command = apply

  variables {
    services = {
      api = { image = "api:1.5.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
    }
  }

  plan_options {
    replace = [local_file.stateful_store]
  }

  assert {
    condition     = fileexists(local_file.stateful_store.filename)
    error_message = "the datastore is in state but gone from disk after -replace (create_before_destroy on a fixed name)"
  }
}
