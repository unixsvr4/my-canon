# -----------------------------------------------------------------------------
# Native Terraform tests (terraform test, 1.6+). Run from modules/app_stack:
#
#   terraform init && terraform test
#
# Every run uses `command = plan`: nothing is written, so the suite is fast,
# free and safe to run on every pull request. Each run asserts one behaviour
# of the module's contract - the for_each keys it produces, and the guard rails
# that must REJECT bad input (expect_failures).
# -----------------------------------------------------------------------------

# Shared baseline input; individual runs override only what they test.
variables {
  name_prefix = "canon-test"
  environment = "dev"
  tags        = { Owner = "platform" }
  services = {
    api    = { image = "api:1.4.2", cpu = 256, memory = 512, public = true, ports = [443, 8443] }
    web    = { image = "web:2.1.0", cpu = 256, memory = 512, ports = [443] }
    worker = { image = "worker:0.9.1", cpu = 256, memory = 512 }
  }
}

# --- for_each over a map: one instance per key, addressed by name -----------
run "service_instances_are_keyed_by_name" {
  command = plan

  assert {
    condition     = toset(keys(local_file.service)) == toset(["api", "web", "worker"])
    error_message = "expected exactly one service instance per map key"
  }

  assert {
    condition     = local_file.service["api"].filename == "./.artifacts/canon-test-api.json"
    error_message = "service filename should be derived from name_prefix and the map key"
  }
}

# --- flatten: service x port becomes stable composite keys -------------------
run "listeners_use_composite_service_port_keys" {
  command = plan

  assert {
    condition     = toset(keys(local_file.listener)) == toset(["api-443", "api-8443", "web-443"])
    error_message = "expected one listener per service x port, keyed service-port (worker has no ports)"
  }
}

# --- filtered for_each: only public services get an endpoint -----------------
run "only_public_services_get_endpoints" {
  command = plan

  assert {
    condition     = keys(local_file.public_endpoint) == ["api"]
    error_message = "only services with public = true should get an endpoint"
  }
}

run "no_public_services_means_zero_instances" {
  command = plan

  variables {
    services = {
      web = { image = "web:2.1.0", cpu = 256, memory = 512, ports = [443] }
    }
  }

  assert {
    condition     = length(local_file.public_endpoint) == 0
    error_message = "an empty filtered map must yield zero instances, not an error"
  }
}

# --- for_each over another resource: keys follow the source resource ---------
run "runbooks_follow_services" {
  command = plan

  assert {
    condition     = toset(keys(local_file.runbook)) == toset(keys(local_file.service))
    error_message = "every service must get exactly one runbook, with matching keys"
  }
}

# --- regression: a shared dependency must not re-couple for_each instances ----
# An earlier version used ONE deploy id for the whole stack; removing a service
# replaced every other service. Deploy ids must be keyed like the services.
run "deploy_ids_are_keyed_per_service" {
  command = plan

  assert {
    condition     = toset(keys(random_id.deploy)) == toset(keys(var.services))
    error_message = "random_id.deploy must have one instance per service key, not one shared instance"
  }
}

# --- optional() defaults ------------------------------------------------------
run "optional_attributes_take_defaults" {
  command = plan

  assert {
    # Asserted on the variable, not the rendered file: the file's content embeds
    # random_id.deploy.hex, which is unknown until apply, so a plan-only run
    # cannot evaluate it. The typed variable already has the default applied.
    condition     = var.services["worker"].desired_count == 1 && var.services["worker"].public == false
    error_message = "desired_count should default to 1 and public to false when omitted"
  }
}

# --- guard rails: these runs PASS only if the module REJECTS the input -------
run "prod_rejects_a_single_replica" {
  command = plan

  variables {
    environment = "prod"
    services = {
      api = { image = "api:1.4.2", cpu = 512, memory = 1024, desired_count = 1 }
    }
  }

  expect_failures = [local_file.service]
}

run "rejects_latest_image_tag" {
  command = plan

  variables {
    services = {
      api = { image = "api:latest", cpu = 256, memory = 512 }
    }
  }

  expect_failures = [var.services]
}

run "rejects_duplicate_ports" {
  command = plan

  variables {
    services = {
      api = { image = "api:1.4.2", cpu = 256, memory = 512, ports = [443, 443] }
    }
  }

  expect_failures = [var.services]
}

run "rejects_public_service_without_ports" {
  command = plan

  variables {
    services = {
      api = { image = "api:1.4.2", cpu = 256, memory = 512, public = true }
    }
  }

  expect_failures = [local_file.public_endpoint]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}
