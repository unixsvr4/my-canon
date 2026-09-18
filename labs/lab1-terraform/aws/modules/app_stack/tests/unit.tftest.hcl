# -----------------------------------------------------------------------------
# Unit tests: `command = plan`. No AWS account, no credentials, no cost.
#
# `mock_provider` (Terraform 1.7+) answers every provider call locally, so these
# runs exercise THIS MODULE'S logic - the for_each shapes, the composite keys,
# the validations and the preconditions - without reaching AWS. What a mock
# cannot test is AWS itself; see tests/README.md for where that line falls.
#
# The negative tests matter more than the positive ones. A guard rail nobody has
# watched fail is a guard rail nobody knows works: each `expect_failures` run
# below is an input that a real deployment would have accepted and regretted.
# -----------------------------------------------------------------------------

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  # Without this default, every role and key policy fails with
  # `"assume_role_policy" contains an invalid JSON policy: not a JSON object`.
  #
  # A mock generates a RANDOM STRING for each computed attribute, and the
  # provider's own schema validation still runs: it rejects a random string in
  # an attribute that must be JSON. So any computed value another resource
  # PARSES - policy documents, JSON bodies, ARNs matched by a regex - needs a
  # realistic default here. Mocks remove the API call, not the provider's rules.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name_prefix         = "canon-test"
  environment         = "dev"
  vpc_id              = "vpc-0123456789abcdef0"
  private_subnet_ids  = ["subnet-0aaa", "subnet-0bbb"]
  public_subnet_ids   = ["subnet-0ccc", "subnet-0ddd"]
  certificate_arn     = "arn:aws:acm:us-east-1:111122223333:certificate/1111-2222"
  hosted_zone_id      = "Z0123456789ABCDEFGHIJ"
  domain              = "canon.example"
  access_logs_bucket  = "canon-alb-logs"
  deletion_protection = false
  tags                = { Owner = "platform", CostCenter = "cc-1234" }

  services = {
    api = { image = "canon/api:1.4.2", cpu = 256, memory = 512, desired_count = 1, public = true, ports = [443, 8443] }
    web = { image = "canon/web:2.1.0", cpu = 256, memory = 512, desired_count = 1, public = true, ports = [443] }
    job = { image = "canon/job:0.9.1", cpu = 256, memory = 512, desired_count = 1 } # no ports, not public
  }
}

# --- The for_each shapes -------------------------------------------------------

run "one_service_per_map_key" {
  command = plan

  assert {
    condition     = length(aws_ecs_service.this) == 3 && length(aws_ecs_task_definition.this) == 3
    error_message = "a map of 3 services must produce 3 services and 3 task definitions"
  }

  # Per-service task roles, not one shared role: this is the blast radius.
  assert {
    condition     = length(aws_iam_role.task) == 3
    error_message = "each service must get its own task role"
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.service) == 3
    error_message = "each service must own its log group, so retention and KMS are set from the start"
  }
}

run "flattened_keys_are_service_and_port" {
  command = plan

  # B: the composite key. This is the shape that makes removing one port a
  # one-resource change.
  assert {
    condition     = toset(keys(local.listeners)) == toset(["api-443", "api-8443", "web-443"])
    error_message = "listener keys must be service-port over every public service x port"
  }

  # One listener per DISTINCT port, shared by the rules - not one per service.
  assert {
    condition     = toset(keys(local.public_ports)) == toset(["443", "8443"])
    error_message = "listeners must be deduplicated by port"
  }

  assert {
    condition     = length(aws_lb_listener_rule.this) == 3
    error_message = "one forwarding rule per service x port"
  }

  # The composite key really does decompose into the service and the port it
  # was built from. Whether the rule then attaches to the RIGHT listener is a
  # comparison of two ARNs that do not exist until apply, so that assertion
  # lives in integration.tftest.hcl - a plan-only test gets
  # "Condition expression could not be evaluated at this time".
  assert {
    condition     = local.listeners["api-8443"].service == "api" && local.listeners["api-8443"].port == 8443
    error_message = "the composite key must carry its own service and port"
  }

  # Priorities are derived from sorted keys, so they are stable across runs.
  assert {
    condition     = local.rule_priority["api-443"] < local.rule_priority["web-443"]
    error_message = "rule priorities must be derived from sorted keys, not from map order"
  }
}

run "filtered_map_excludes_private_services" {
  command = plan

  # C: `job` is not public, so it gets no DNS record and no listener rule -
  # with no `count` ternary anywhere.
  assert {
    condition     = toset(keys(aws_route53_record.public)) == toset(["api", "web"])
    error_message = "only public services get a DNS record"
  }

  assert {
    condition     = !contains(keys(local.listeners), "job-443")
    error_message = "a service with no ports must not appear in the listener map"
  }
}

run "alarms_follow_the_service_resource" {
  command = plan

  # D: for_each over another resource's instances - add a service, get its
  # alarms, with no second list to maintain.
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.unhealthy_tasks) == 3
    error_message = "every service must get a running-task alarm"
  }

  # Missing data is the incident for this alarm, not the absence of one.
  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.unhealthy_tasks : a.treat_missing_data == "breaching"
    ])
    error_message = "a 'tasks have died' alarm must treat missing data as breaching"
  }
}

# --- Policy that must hold at plan time ---------------------------------------

run "security_posture" {
  command = plan

  assert {
    condition = alltrue([
      for l in aws_lb_listener.https : l.protocol == "HTTPS" && l.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    ])
    error_message = "every public listener must be HTTPS on a TLS 1.2+ policy"
  }

  # Port 80 exists only to redirect.
  assert {
    condition     = aws_lb_listener.redirect.default_action[0].type == "redirect"
    error_message = "the port 80 listener must redirect, never forward"
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "the ALB must drop invalid header fields"
  }

  # Only that encryption is ON. WHICH key it uses is aws_kms_key.this.arn, a
  # value that does not exist until apply, so integration.tftest.hcl asserts
  # that the database, the log groups and the secret all landed on the same CMK.
  assert {
    condition     = aws_db_instance.this.storage_encrypted
    error_message = "the database must be encrypted"
  }

  assert {
    condition     = !aws_db_instance.this.publicly_accessible
    error_message = "the database must not be publicly accessible"
  }

  # The credential never enters state: RDS generates and rotates it into
  # Secrets Manager, and the task definition consumes the ARN.
  assert {
    condition     = aws_db_instance.this.manage_master_user_password
    error_message = "the master password must be managed by RDS, not set in Terraform"
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation
    error_message = "the stack CMK must have rotation enabled"
  }

  # Tasks never run in a public subnet with a public IP.
  assert {
    condition = alltrue([
      for svc in aws_ecs_service.this : !svc.network_configuration[0].assign_public_ip
    ])
    error_message = "Fargate tasks must not be given public IPs"
  }

  # Retention is a literal input, so it is known at plan. "Never expire" is the
  # CloudWatch default and it bills forever.
  assert {
    condition = alltrue([
      for lg in aws_cloudwatch_log_group.service : lg.retention_in_days == 30
    ])
    error_message = "log groups must have an explicit retention"
  }
}

run "mandatory_tags_on_every_taggable_resource" {
  command = plan

  assert {
    condition = alltrue([
      for tag in ["Environment", "ManagedBy", "Module", "Owner", "CostCenter"] :
      contains(keys(aws_db_instance.this.tags), tag)
    ])
    error_message = "the database is missing a mandatory tag"
  }

  # The Service tag is what Lab 2's dynamic inventory groups on, so it has to
  # be on the per-service resources, not just the stack-level ones.
  assert {
    condition = alltrue([
      for key, svc in aws_ecs_service.this : svc.tags["Service"] == key
    ])
    error_message = "every service resource must carry its own Service tag"
  }

  # A caller can add tags but must never be able to drop the module's.
  assert {
    condition     = aws_ecs_cluster.this.tags["ManagedBy"] == "terraform" && aws_ecs_cluster.this.tags["Owner"] == "platform"
    error_message = "caller tags must merge over, not replace, the module's tag contract"
  }
}

run "target_group_name_prefix_fits_the_api_limit" {
  command = plan

  # create_before_destroy forces name_prefix, and the ELB API caps name_prefix
  # at six characters. A test, because the failure mode is an apply that dies
  # on one resource out of forty.
  assert {
    condition = alltrue([
      for tg in aws_lb_target_group.this : length(tg.name_prefix) <= 6
    ])
    error_message = "target group name_prefix must be at most 6 characters"
  }
}

# --- Guard rails: each of these is an input a real deployment would regret -----

run "reject_mutable_image_tag" {
  command = plan

  variables {
    services = {
      api = { image = "canon/api:latest", cpu = 256, memory = 512 }
    }
  }

  expect_failures = [var.services]
}

run "reject_invalid_fargate_cpu" {
  command = plan

  variables {
    services = {
      api = { image = "canon/api:1.0.0", cpu = 300, memory = 1024 }
    }
  }

  expect_failures = [var.services]
}

run "reject_duplicate_port" {
  command = plan

  variables {
    services = {
      api = { image = "canon/api:1.0.0", cpu = 256, memory = 512, public = true, ports = [443, 443] }
    }
  }

  expect_failures = [var.services]
}

run "reject_public_service_with_no_ports" {
  command = plan

  variables {
    services = {
      api = { image = "canon/api:1.0.0", cpu = 256, memory = 512, public = true, ports = [] }
    }
  }

  expect_failures = [var.services]
}

run "reject_unusable_service_key" {
  command = plan

  variables {
    services = {
      "API_Gateway" = { image = "canon/api:1.0.0", cpu = 256, memory = 512 }
    }
  }

  expect_failures = [var.services]
}

run "reject_single_subnet" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-0aaa"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "reject_malformed_vpc_id" {
  command = plan

  variables {
    vpc_id = "my-vpc"
  }

  expect_failures = [var.vpc_id]
}

run "reject_log_retention_cloudwatch_would_not_accept" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

# --- Guard rails that depend on the environment, so they live in preconditions -

run "prod_refuses_a_single_task" {
  command = plan

  variables {
    environment         = "prod"
    deletion_protection = true
    db_instance_class   = "db.t4g.medium"

    services = {
      api = { image = "canon/api:1.4.2", cpu = 256, memory = 512, desired_count = 1, public = true, ports = [443] }
    }
  }

  expect_failures = [aws_ecs_service.this["api"]]
}

run "prod_refuses_deletion_protection_off" {
  command = plan

  variables {
    environment         = "prod"
    deletion_protection = false
    db_instance_class   = "db.t4g.medium"

    services = {
      api = { image = "canon/api:1.4.2", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443] }
    }
  }

  expect_failures = [aws_db_instance.this]
}

run "prod_refuses_a_micro_database" {
  command = plan

  variables {
    environment         = "prod"
    deletion_protection = true
    db_instance_class   = "db.t4g.micro"

    services = {
      api = { image = "canon/api:1.4.2", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443] }
    }
  }

  expect_failures = [aws_db_instance.this]
}
