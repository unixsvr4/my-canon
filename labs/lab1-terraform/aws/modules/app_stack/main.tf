# -----------------------------------------------------------------------------
# main.tf - app_stack on AWS: ECS Fargate services behind a shared ALB, with a
# PostgreSQL database, on a network this module does not own.
#
# This is the real implementation of ../../../modules/app_stack. That module
# models each of these with a local_file so the lab costs nothing; the STRUCTURE
# is the same, resource for resource:
#
#   local_file.service          -> aws_ecs_task_definition + aws_ecs_service
#   local_file.listener         -> aws_lb_target_group + aws_lb_listener_rule
#   local_file.public_endpoint  -> aws_route53_record
#   local_file.runbook          -> aws_cloudwatch_metric_alarm + dashboard
#   local_file.stateful_store   -> aws_db_instance
#
# The same tour of for_each, in the same order:
#   A. for_each over a map of objects          (this file: task defs, services)
#   B. for_each over a FLATTENED nested map    (alb.tf: listener rules)
#   C. for_each over a FILTERED map            (dns.tf: records)
#   D. for_each over ANOTHER RESOURCE          (observability.tf: alarms)
#   E. no for_each at all, and why             (database.tf: the RDS instance)
# -----------------------------------------------------------------------------

locals {
  # Tag contract. Module-owned keys first, then caller tags, so a caller can ADD
  # tags but can never drop Environment/ManagedBy/Module - the keys cost
  # reports, audits and Lab 2's dynamic inventory all key on.
  #
  # `Service` is added per resource where it applies. That tag is not decoration:
  # it is what makes `aws_ec2`/resource-group inventories in Lab 2 able to
  # select "the api hosts" without a second list to keep in sync.
  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "app_stack"
    },
    var.tags,
  )

  # --- for B: flatten a nested structure into a map with a composite key -------
  #
  # for_each needs ONE flat map. Services contain lists of ports, so:
  #   1. the inner `for` produces a listener object per service x port,
  #   2. flatten() turns the list-of-lists into one list,
  #   3. the outer `for` turns that list into a map keyed "service-port".
  #
  # Input:   { api = { ports = [443, 8443] }, web = { ports = [443] } }
  # Result:  { "api-443", "api-8443", "web-443" }
  #
  # The composite key is the design decision that matters: STABLE and UNIQUE.
  # Removing port 8443 from api destroys exactly the "api-8443" listener rule
  # and nothing else. Uniqueness is enforced by a validation in variables.tf.
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

  # One ALB listener per distinct public port, shared by every service's rules.
  # A listener per service would mean a load balancer per service: ~16 USD a
  # month each, and a certificate to attach to each one.
  #
  # A MAP keyed by the port's string form, not `toset([443, 8443])`, because
  # for_each keys are always STRINGS: a set of numbers is rejected outright with
  # "for_each supports maps and sets of strings, but you have provided a set
  # containing type number". Keeping the numeric value means nothing downstream
  # has to convert it back to set a port.
  #
  # distinct() runs BEFORE the map is built, and that order is not optional: two
  # public services both on 443 would otherwise produce the key "443" twice, and
  # a `for` expression refuses duplicate keys outright ("Two different items
  # produced the key 443"). Deduplicating inside the map expression is not
  # possible - only `...` grouping is, which would give a list per port.
  public_ports = {
    for p in distinct([for k, l in local.listeners : l.port if l.public]) : tostring(p) => p
  }

  # --- for C: filter a map with an `if` clause --------------------------------
  public_services = { for name, svc in var.services : name => svc if svc.public }

  # Listener-rule priorities must be unique per listener and are integers, not
  # names. Deriving them from a SORTED key list keeps them stable: adding a
  # service does not renumber the others as long as it sorts last. Sorting by
  # name rather than by map iteration order is the part that matters - map order
  # is stable in Terraform, but the intent should be explicit in the code.
  rule_priority = { for idx, key in sort(keys(local.listeners)) : key => 100 + idx }
}

# -----------------------------------------------------------------------------
# A customer-managed KMS key for this stack's logs, database and secrets.
#
# AWS-managed keys are free but shared, unrotatable on your schedule, and give
# no way to deny a compromised principal without touching every service. One
# CMK per stack with rotation on is the auditable default; the cost is 1 USD a
# month plus request charges.
# -----------------------------------------------------------------------------
resource "aws_kms_key" "this" {
  description             = "${var.name_prefix} app_stack: logs, database and secrets"
  enable_key_rotation     = true
  deletion_window_in_days = var.environment == "prod" ? 30 : 7

  # CloudWatch Logs encrypts with the key on the caller's behalf, so the logs
  # service must be allowed to use it, scoped to this account's log groups.
  policy = data.aws_iam_policy_document.kms.json

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-app-stack" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}-app-stack"
  target_key_id = aws_kms_key.this.key_id
}

# -----------------------------------------------------------------------------
# One log group per service, created and owned here.
#
# Not left to the awslogs driver: a log group created implicitly by the first
# task has no retention (logs kept forever, billed forever), no KMS key, and no
# tags, and it survives `terraform destroy` because nothing in state owns it.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "service" {
  for_each = var.services

  name              = "/aws/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}", Service = each.key })
}

resource "aws_cloudwatch_log_group" "exec" {
  name              = "/aws/ecs/${var.name_prefix}/exec"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-exec" })
}

# -----------------------------------------------------------------------------
# The cluster.
#
# containerInsights is on because the alarms in observability.tf need the
# metrics, and turning observability on after an incident is too late.
#
# executeCommandConfiguration routes `aws ecs execute-command` (a shell in a
# running task, over SSM - the same control plane Lab 2 uses instead of SSH)
# through an encrypted, retained log group. Interactive access to production
# that nothing records is an audit finding waiting to happen.
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.this.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec.name
      }
    }
  }

  tags = merge(local.common_tags, { Name = var.name_prefix })
}

# -----------------------------------------------------------------------------
# A. for_each over a map of objects - the task definition.
#
#   each.key   -> the map key ("api")
#   each.value -> that service's object ({ image, cpu, memory, ... })
#   address    -> aws_ecs_task_definition.this["api"]
#
# Every `aws_ecs_task_definition` apply creates a new REVISION; the resource is
# a pointer to the latest one. That is why the service below references
# `.arn` (revision-pinned) and not the family name: a deploy is an explicit
# move to a known revision, so a rollback is a revision number, not a rebuild.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  for_each = var.services

  family                   = "${var.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task[each.key].arn

  runtime_platform {
    cpu_architecture        = "ARM64" # Graviton: ~20% cheaper per vCPU-hour than X86_64
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = each.value.image
      essential = true

      # readonlyRootFilesystem is the single highest-value container setting
      # here: it turns "attacker writes a webshell into the app directory" into
      # a failed write. Anything the app must write gets an explicit tmpfs.
      readonlyRootFilesystem = true
      user                   = "10001:10001"

      linuxParameters = {
        initProcessEnabled = true # reaps zombies; without it PID 1 leaks processes
      }

      portMappings = [
        for p in each.value.ports : { containerPort = p, protocol = "tcp" }
      ]

      environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "SERVICE", value = each.key },
        { name = "DB_HOST", value = aws_db_instance.this.address },
        { name = "DB_NAME", value = aws_db_instance.this.db_name },
      ]

      # Credentials arrive as `secrets`, never as `environment`. An environment
      # variable is visible in the task definition, in `describe-task-definition`
      # output, and to anyone with read access to the console. `secrets` makes
      # the agent fetch the value at task start, and the task definition holds
      # only the ARN.
      secrets = [
        { name = "DB_SECRET", valueFrom = aws_db_instance.this.master_user_secret[0].secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = each.key
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://localhost:${try(each.value.ports[0], 8080)}${each.value.health_path} || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}", Service = each.key })
}

# -----------------------------------------------------------------------------
# A. for_each over a map of objects - the service.
#
# The guard rails are `precondition`s: they fail in PLAN, per key, with a
# readable message - in the pull request, not twenty minutes into an apply as a
# provider API error.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  for_each = var.services

  name            = "${var.name_prefix}-${each.key}"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this[each.key].arn
  desired_count   = each.value.desired_count
  launch_type     = "FARGATE"
  propagate_tags  = "SERVICE"

  # A shell in a running task, over SSM, audited into the log group above.
  enable_execute_command = true

  # Without a circuit breaker a broken image is a deploy that never finishes:
  # ECS keeps starting tasks that keep dying until someone notices. With it,
  # ECS gives up and puts the previous revision back on its own.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 200/100 means: start the new tasks, only then stop the old ones. At 100/0 a
  # deploy takes the service down to zero first, which is a rolling restart of
  # an outage. Costs one extra task's capacity for the length of a deploy.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false # tasks reach the internet through a NAT gateway or VPC endpoints
  }

  # Attach this service to its own target group, on its first port. Indexing a
  # for_each resource by key is how one instance finds "its" partner without
  # positional coupling.
  dynamic "load_balancer" {
    for_each = length(each.value.ports) > 0 ? [each.value.ports[0]] : []

    content {
      target_group_arn = aws_lb_target_group.this[each.key].arn
      container_name   = each.key
      container_port   = load_balancer.value
    }
  }

  # Give the container its startPeriod before the ALB starts failing it, or a
  # slow-starting app is killed and restarted forever.
  health_check_grace_period_seconds = length(each.value.ports) > 0 ? 60 : null

  lifecycle {
    precondition {
      condition     = var.environment != "prod" || each.value.desired_count >= 2
      error_message = "Service ${each.key}: prod requires desired_count >= 2 so one task can fail (and so a deploy has somewhere to go)."
    }

    precondition {
      condition     = !each.value.public || length(each.value.ports) > 0
      error_message = "Service ${each.key} is public but exposes no ports - there is nothing for the load balancer to forward to."
    }
  }

  # The listener rule must exist before the service registers targets, or the
  # first tasks are healthy in a target group nothing routes to.
  depends_on = [aws_lb_listener_rule.this]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}", Service = each.key })
}
