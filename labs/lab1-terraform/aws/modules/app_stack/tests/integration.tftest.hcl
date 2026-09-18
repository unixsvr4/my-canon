# -----------------------------------------------------------------------------
# Integration tests: `command = apply`, against a MOCKED AWS.
#
# unit.tftest.hcl proves the PLAN is right. This file proves the RESULT is
# right: that the graph resolves, that every reference between resources lands
# on its own partner, and - the part a plan can never show - that changing one
# service leaves the others' applied values untouched.
#
# The runs share state and execute in order, so each is a lifecycle step:
#   1. create          -> everything exists and is wired to the right partner
#   2. update api      -> only api's task definition moves; web's does not
#   3. remove web      -> web's resources are gone; api is untouched
#   4. add a port      -> exactly one new listener rule; the rest unchanged
#
# `terraform test` destroys everything it created, in reverse run order, when
# the file finishes. Against mocks that is instant and free; against a real
# sandbox account it is the same code and the same teardown.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
# It proves this module's logic. It cannot prove AWS's: a mock accepts an
# invalid subnet id, an ALB name that is already taken, an IAM policy that
# denies what the task needs, or a Fargate cpu/memory pair the API rejects.
# That is the job of `tflint` (provider-aware rules), `trivy` (misconfiguration
# policy), the variable validations, and one periodic apply into a sandbox
# account. Mocks buy speed and zero cost, not certainty.
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

  # See the note in unit.tftest.hcl: provider-side validation still runs, so a
  # computed value that another resource parses needs a realistic default.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # An ARN a mock invents is a random 8-character string, and the provider
  # validates the FORMAT of any attribute declared as an ARN, so
  # `load_balancer_arn = aws_lb.this.arn` fails the apply with
  # `"load_balancer_arn" (g37mq6n0) is an invalid ARN: arn: invalid prefix`.
  # Plan-only runs never hit this: at plan the value is unknown, and validation
  # skips unknowns. It appears the moment you switch a run to `command = apply`.
  #
  # THE TRAP IN THE FIX: a `defaults` block applies to EVERY instance of that
  # resource type. Defaulting aws_lb_target_group.arn would give api and web the
  # SAME arn, and every "each rule forwards to its own service's target group"
  # assertion below would pass without proving anything. So a fixed ARN is set
  # only for the resources this module has exactly one of - the load balancer
  # and the CMK - and everything that exists per key keeps its random value.
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/canon-itest/1111222233334444"
      arn_suffix = "app/canon-itest/1111222233334444"
      dns_name   = "canon-itest-1234567890.us-east-1.elb.amazonaws.com"
      zone_id    = "Z35SXDOTRQ7X7K"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }

  # RDS generates the master credential into Secrets Manager, so the secret ARN
  # is a computed NESTED BLOCK. A mock leaves nested blocks empty unless told
  # otherwise, and `master_user_secret[0]` on an empty list fails the apply with
  # "Invalid index". Anything a mocked resource exposes through a block, and
  # another resource then indexes, has to be defaulted here.
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!canon-itest-db-abc123"
        kms_key_id    = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        secret_status = "active"
      }]
    }
  }
}

# -----------------------------------------------------------------------------
# `override_resource` where `mock_resource` would be too blunt.
#
# task_role_arn and execution_role_arn are ARN-validated AND per service, so the
# random mock value fails the apply - but a type-wide `mock_resource "aws_iam_role"`
# default would hand api and web the SAME role ARN, and "each task definition
# uses its own service's role" would then be true by construction.
#
# override_resource targets ONE instance, so each service gets a distinct, valid
# ARN and the assertion still has something to catch. This is the difference
# between the two blocks: mock_resource is per TYPE, override_resource is per
# ADDRESS.
# -----------------------------------------------------------------------------
override_resource {
  target = aws_iam_role.execution
  values = {
    arn = "arn:aws:iam::111122223333:role/canon-itest-ecs-execution"
  }
}

override_resource {
  target = aws_iam_role.task["api"]
  values = {
    arn = "arn:aws:iam::111122223333:role/canon-itest-api-task"
  }
}

override_resource {
  target = aws_iam_role.task["web"]
  values = {
    arn = "arn:aws:iam::111122223333:role/canon-itest-web-task"
  }
}

# The same reasoning for the load-balancer objects a rule points at. Each key
# gets its OWN ARN, so "the rule for api-8443 attaches to the 8443 listener and
# forwards to api's target group" is still a claim that can fail.
#
# Port 9443 is only used by the last run; an override for an address that does
# not exist in a given run is simply unused.
override_resource {
  target = aws_lb_listener.https["443"]
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/canon-itest/1111222233334444/aaaa000000000443"
  }
}

override_resource {
  target = aws_lb_listener.https["8443"]
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/canon-itest/1111222233334444/aaaa000000008443"
  }
}

override_resource {
  target = aws_lb_listener.https["9443"]
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/canon-itest/1111222233334444/aaaa000000009443"
  }
}

override_resource {
  target = aws_lb_listener.redirect
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/canon-itest/1111222233334444/aaaa000000000080"
  }
}

override_resource {
  target = aws_lb_target_group.this["api"]
  values = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/api001-aaaa/1111000000000001"
    arn_suffix = "targetgroup/api001-aaaa/1111000000000001"
  }
}

override_resource {
  target = aws_lb_target_group.this["web"]
  values = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/web001-bbbb/1111000000000002"
    arn_suffix = "targetgroup/web001-bbbb/1111000000000002"
  }
}

variables {
  name_prefix         = "canon-itest"
  environment         = "prod"
  vpc_id              = "vpc-0123456789abcdef0"
  private_subnet_ids  = ["subnet-0aaa", "subnet-0bbb"]
  public_subnet_ids   = ["subnet-0ccc", "subnet-0ddd"]
  certificate_arn     = "arn:aws:acm:us-east-1:111122223333:certificate/1111-2222"
  hosted_zone_id      = "Z0123456789ABCDEFGHIJ"
  domain              = "canon.example"
  access_logs_bucket  = "canon-alb-logs"
  deletion_protection = true
  db_instance_class   = "db.t4g.medium"
  tags                = { Owner = "platform", CostCenter = "cc-1234" }

  services = {
    api = { image = "canon/api:1.4.2", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
    web = { image = "canon/web:2.1.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443] }
  }
}

# --- 1. create: every reference lands on its own partner ----------------------
run "create" {
  command = apply

  # B, proven: each rule attaches to the listener for ITS port. This is the
  # assertion unit.tftest.hcl could not make, because both ARNs are computed.
  assert {
    condition = alltrue([
      for key, rule in aws_lb_listener_rule.this :
      rule.listener_arn == aws_lb_listener.https[tostring(local.listeners[key].port)].arn
    ])
    error_message = "a listener rule is attached to the wrong port's listener"
  }

  # ...and forwards to its OWN service's target group, not a neighbour's.
  assert {
    condition = alltrue([
      for key, rule in aws_lb_listener_rule.this :
      rule.action[0].target_group_arn == aws_lb_target_group.this[local.listeners[key].service].arn
    ])
    error_message = "a listener rule forwards to another service's target group"
  }

  # Each ECS service runs its own task definition revision and registers into
  # its own target group.
  #
  # one(), not [0]: `load_balancer` is a SET in the provider schema, and set
  # elements have no index ("Elements of a set are identified only by their
  # value"). one() returns the single element, and fails loudly if there is ever
  # more than one - which is what you want from an assertion.
  assert {
    condition = alltrue([
      for key, svc in aws_ecs_service.this :
      svc.task_definition == aws_ecs_task_definition.this[key].arn &&
      one(svc.load_balancer).target_group_arn == aws_lb_target_group.this[key].arn &&
      one(svc.load_balancer).container_name == key
    ])
    error_message = "a service is wired to the wrong task definition or target group"
  }

  # Per-service task role, and it is the one the task definition actually uses.
  assert {
    condition = alltrue([
      for key, td in aws_ecs_task_definition.this :
      td.task_role_arn == aws_iam_role.task[key].arn && td.execution_role_arn == aws_iam_role.execution.arn
    ])
    error_message = "a task definition does not use its own service's task role"
  }

  # Every service logs to its own group, and the group is the one the container
  # definition names. A wrong awslogs-group is silent: the tasks run, and the
  # logs are somewhere nobody looks.
  assert {
    condition = alltrue([
      for key, td in aws_ecs_task_definition.this :
      jsondecode(td.container_definitions)[0].logConfiguration.options["awslogs-group"] == aws_cloudwatch_log_group.service[key].name
    ])
    error_message = "a container logs to the wrong log group"
  }

  # The database credential reaches the container as a `secrets` reference and
  # NOT as an environment variable. This is the assertion that would have caught
  # the credential being pasted into `environment` during a hurried fix.
  assert {
    condition = alltrue([
      for key, td in aws_ecs_task_definition.this :
      jsondecode(td.container_definitions)[0].secrets[0].valueFrom == aws_db_instance.this.master_user_secret[0].secret_arn &&
      !contains([for e in jsondecode(td.container_definitions)[0].environment : e.name], "DB_SECRET")
    ])
    error_message = "the database credential must arrive as a secret reference, never in environment"
  }

  assert {
    condition = alltrue([
      for key, td in aws_ecs_task_definition.this :
      jsondecode(td.container_definitions)[0].readonlyRootFilesystem
    ])
    error_message = "containers must run with a read-only root filesystem"
  }

  # One CMK, used by everything that encrypts: the log groups, the database and
  # the RDS-managed secret. A second, implicitly-created AWS-managed key is the
  # usual way this goes wrong, and it is invisible until an audit.
  assert {
    condition = alltrue(concat(
      [for lg in aws_cloudwatch_log_group.service : lg.kms_key_id == aws_kms_key.this.arn],
      [aws_db_instance.this.kms_key_id == aws_kms_key.this.arn],
      [aws_db_instance.this.master_user_secret_kms_key_id == aws_kms_key.this.arn],
      [aws_db_instance.this.performance_insights_kms_key_id == aws_kms_key.this.arn],
    ))
    error_message = "something in the stack is encrypted with a key other than the stack CMK"
  }

  # C: public records exist for public services only, and alias the ALB.
  assert {
    condition = alltrue([
      for key, r in aws_route53_record.public :
      r.alias[0].name == aws_lb.this.dns_name && r.alias[0].evaluate_target_health
    ])
    error_message = "a public record does not alias the load balancer with target health evaluation"
  }

  # Alarms are keyed to the real, applied service names and desired counts.
  assert {
    condition = alltrue([
      for key, a in aws_cloudwatch_metric_alarm.unhealthy_tasks :
      a.dimensions["ServiceName"] == aws_ecs_service.this[key].name &&
      a.dimensions["ClusterName"] == aws_ecs_cluster.this.name &&
      a.threshold == var.services[key].desired_count
    ])
    error_message = "an alarm is watching the wrong service or the wrong threshold"
  }

  # prod: Multi-AZ, 30-day backups, deletion protection, a final snapshot.
  assert {
    condition = (aws_db_instance.this.multi_az &&
      aws_db_instance.this.backup_retention_period == 30 &&
      aws_db_instance.this.deletion_protection &&
      !aws_db_instance.this.skip_final_snapshot
    )
    error_message = "prod database must be multi-AZ, backed up for 30 days, deletion-protected and snapshot on destroy"
  }

  # The outputs a consumer depends on describe what was really built.
  assert {
    condition = (output.service_names == { for k, s in aws_ecs_service.this : k => s.name } &&
      output.listeners == { "api-443" = 443, "api-8443" = 8443, "web-443" = 443 } &&
      toset(keys(output.public_endpoints)) == toset(["api", "web"])
    )
    error_message = "the outputs do not match the applied resources"
  }
}

# --- 2. update one service: the others must not move --------------------------
run "update_api_image" {
  command = apply

  variables {
    services = {
      api = { image = "canon/api:1.5.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
      web = { image = "canon/web:2.1.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443] }
    }
  }

  # A new image renders a new definition for api.
  #
  # The comparison is on the DIGEST, not the task definition ARN. A mocked
  # provider does not implement force-replacement: it generated api's ARN once,
  # and returns the same value even though a real apply would cut a new
  # revision. "Was this resource replaced?" is therefore not a question a mock
  # can answer, and an assertion phrased that way passes for the wrong reason.
  # The digest is computed by Terraform from the configuration, so it is honest
  # here and identical in behaviour against a real account.
  assert {
    condition     = output.task_definition_digests["api"] != run.create.task_definition_digests["api"]
    error_message = "api's image changed, so its rendered task definition must change"
  }

  # THE COUPLING TEST. If anything in this module were shared between services -
  # one task role, one log group, one generated id embedded in every definition -
  # web's digest would move when api's image changed, and this fails. It is the
  # AWS form of the bug recorded as T1 in RESEARCH.md, where one shared
  # random_id meant removing `web` replaced `api`.
  assert {
    condition     = output.task_definition_digests["web"] == run.create.task_definition_digests["web"]
    error_message = "web was not changed, so its definition must not move (cross-service coupling)"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["api"].container_definitions)[0].image == "canon/api:1.5.0"
    error_message = "the new image did not reach the applied task definition"
  }
}

# --- 3. remove a service: its resources go, the rest stay ---------------------
run "remove_web" {
  command = apply

  variables {
    services = {
      api = { image = "canon/api:1.5.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443] }
    }
  }

  assert {
    condition = (toset(keys(output.service_names)) == toset(["api"]) &&
      toset(keys(output.public_endpoints)) == toset(["api"]) &&
      toset(keys(output.listeners)) == toset(["api-443", "api-8443"])
    )
    error_message = "removing web from the map must remove web's resources, not orphan them"
  }

  # Everything keyed per service has to go with it: the target group, the log
  # group, the task role. An orphaned log group keeps billing; an orphaned role
  # is a standing credential nobody owns.
  assert {
    condition = (!contains(keys(aws_lb_target_group.this), "web") &&
      !contains(keys(aws_cloudwatch_log_group.service), "web") &&
      !contains(keys(aws_iam_role.task), "web") &&
      !contains(keys(aws_lb_listener_rule.this), "web-443")
    )
    error_message = "a per-service resource was left behind after its service was removed"
  }

  assert {
    condition     = output.task_definition_digests["api"] == run.update_api_image.task_definition_digests["api"]
    error_message = "removing web must not touch api"
  }
}

# --- 4. add a port: exactly one new rule --------------------------------------
# The composite key's reason for existing. With a positional key (count.index
# over a flattened list) inserting a port renumbers everything after it and
# replaces rules that did not change - the failure reproduced in
# ../../examples/03-nested-for-each.
run "add_a_port" {
  command = apply

  variables {
    services = {
      api = { image = "canon/api:1.5.0", cpu = 256, memory = 512, desired_count = 2, public = true, ports = [443, 8443, 9443] }
    }
  }

  assert {
    condition     = toset(keys(output.listeners)) == toset(["api-443", "api-8443", "api-9443"])
    error_message = "adding a port must add exactly one listener key"
  }

  # A third listener now exists, and the new rule is on it.
  assert {
    condition     = length(aws_lb_listener.https) == 3 && aws_lb_listener_rule.this["api-9443"].listener_arn == aws_lb_listener.https["9443"].arn
    error_message = "the new port needs its own listener, and the new rule must attach to it"
  }

  # A port is NOT purely a load-balancer concern, and this run is what makes
  # that concrete: the container has to listen on it, so the port appears in the
  # task definition's portMappings and api's digest legitimately moves. The
  # first version of this assertion claimed the opposite and failed - the module
  # was right and the test was wrong.
  #
  # Worth knowing before a change window: "just add a port to the ALB" is a
  # redeploy of the service, not a load-balancer-only edit.
  assert {
    condition     = output.task_definition_digests["api"] != run.remove_web.task_definition_digests["api"]
    error_message = "a new port must reach the container's portMappings"
  }

  assert {
    condition = contains(
      [for m in jsondecode(aws_ecs_task_definition.this["api"].container_definitions)[0].portMappings : m.containerPort],
      9443
    )
    error_message = "the container is not listening on the port the new listener forwards to"
  }
}
