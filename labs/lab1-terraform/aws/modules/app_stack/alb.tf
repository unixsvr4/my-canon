# -----------------------------------------------------------------------------
# alb.tf - one shared Application Load Balancer, and pattern B: for_each over a
# FLATTENED nested map, keyed "service-port".
#
#   aws_lb                  one, shared by every service
#   aws_lb_target_group     one per service          (for_each over the map)
#   aws_lb_listener         one per distinct port     (for_each over a derived map)
#   aws_lb_listener_rule    one per service x port    (for_each over the FLATTENED map)
#
# Three different for_each sources in one file, because the three resources are
# keyed by three different things. Forcing them all to one key is how modules
# end up with rules they cannot remove individually.
# -----------------------------------------------------------------------------

# --- Security groups ----------------------------------------------------------
#
# Two groups, and the rule between them references the OTHER GROUP, not a CIDR.
# That is the part worth copying: the tasks' rule stays correct when the ALB's
# addresses change, when a subnet is added, or when the VPC is re-addressed.
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public listeners for ${var.name_prefix}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-task"
  description = "Fargate tasks for ${var.name_prefix}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-task" })

  lifecycle {
    create_before_destroy = true
  }
}

# ANOTHER FLATTEN, and the reason the modern one-rule-per-resource types exist.
#
# The rule set is port x CIDR, so the key is "443-0.0.0.0/0". With the old
# inline `ingress` blocks inside aws_security_group, adding one CIDR rewrote the
# whole block and replaced every rule in it - there is a demo of exactly that
# failure in ../../examples/03-nested-for-each. With
# aws_vpc_security_group_ingress_rule, one key is one API object: adding a CIDR
# creates one rule and touches nothing else.
resource "aws_vpc_security_group_ingress_rule" "alb_public" {
  for_each = {
    for r in flatten([
      for port in values(local.public_ports) : [
        for cidr in var.public_ingress_cidrs : { key = "${port}-${cidr}", port = port, cidr = cidr }
      ]
    ]) : r.key => r
  }

  security_group_id = aws_security_group.alb.id
  description       = "public access to ${each.value.port} from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alb-${each.key}" })
}

# Port 80 exists only to redirect to 443 (see the listener below), so it is open
# to the same CIDRs. Without it, "http://service.example" is a timeout rather
# than a redirect, and users conclude the service is down.
resource "aws_vpc_security_group_ingress_rule" "alb_redirect" {
  for_each = toset(var.public_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "http to https redirect from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alb-80" })
}

# The ALB reaches the tasks on every port any service exposes. Referenced by
# security group, not CIDR.
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  for_each = local.public_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "forward to tasks on ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.task.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alb-out-${each.value}" })
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  for_each = local.public_ports

  security_group_id            = aws_security_group.task.id
  description                  = "load balancer to task port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-task-in-${each.value}" })
}

# Tasks need 443 out: ECR to pull the image, Secrets Manager for the database
# credential, CloudWatch for logs, SSM for execute-command.
#
# The tighter answer is interface VPC endpoints for exactly those services and
# no egress rule at all, which also removes the NAT gateway from the bill. That
# belongs to the network root, so this module states the requirement and the
# network satisfies it however it is built.
#
# WAIVER: trivy AVD-AWS-0104 flags unrestricted egress. It is restricted to
# ONE port, 443, and the alternative to an IP range here is a managed prefix
# list per AWS service per region - which changes under you, and which this
# module cannot own because it does not own the VPC. The real fix is interface
# endpoints and deleting this rule entirely; until the network provides them,
# this is the honest state of it.
#
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "task_https" {
  security_group_id = aws_security_group.task.id
  description       = "AWS APIs and image pulls over TLS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-task-out-443" })
}

resource "aws_vpc_security_group_egress_rule" "task_to_db" {
  security_group_id            = aws_security_group.task.id
  description                  = "postgresql"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.database.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-task-out-5432" })
}

# --- The load balancer --------------------------------------------------------
#
# WAIVER, with the reason next to the code rather than in a scanner config file.
# trivy AVD-AWS-0053 warns that a load balancer is internet-facing. This one is
# meant to be: it serves the public services, behind HTTPS-only listeners, with
# ingress restricted to var.public_ingress_cidrs. An internal stack sets
# `internal = true` by passing no public subnets, which is a different module
# call, not a different module.
#
#trivy:ignore:AVD-AWS-0053
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  enable_deletion_protection = var.deletion_protection

  # Request smuggling: without this, headers the ALB considers invalid are
  # passed through to the target, which may parse them differently.
  drop_invalid_header_fields = true

  # Access logs are the only record of who called what through the ALB. They go
  # to a bucket in the logging account, which is why the bucket is an input.
  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = "${var.name_prefix}/alb"
    enabled = true
  }

  idle_timeout = 60

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alb" })
}

# --- Target groups: one per service -------------------------------------------
#
# name_prefix, not name, and create_before_destroy - and the two go together.
#
# A target group attached to a listener cannot be deleted, so any change that
# forces replacement (port, protocol, target type) DEADLOCKS on a fixed name:
# Terraform tries to destroy the old group first, the API refuses because the
# listener still references it. create_before_destroy fixes the order, but then
# two groups exist at once and they cannot share a name - so the name has to be
# generated. AWS caps name_prefix at 6 characters and appends a unique suffix.
#
# Compare this with the datastore in the local module (../../modules/app_stack):
# there, create_before_destroy was REMOVED, because that object's name is fixed
# and create-then-destroy at one fixed name deletes the replacement (RESEARCH.md
# T11). Same flag, opposite conclusion, and the deciding question is the same
# one: does the replacement get a new name?
resource "aws_lb_target_group" "this" {
  for_each = var.services

  name_prefix = local.tg_prefix[each.key]
  vpc_id      = var.vpc_id
  port        = try(each.value.ports[0], 8080)
  protocol    = "HTTP" # TLS terminates at the ALB; re-encryption is a separate decision
  target_type = "ip"   # awsvpc tasks register by IP, not by instance

  # 30s, not the 300s default. The default means a deploy holds connections to
  # tasks that are already gone for five minutes, and a rollback takes longer
  # than the incident.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}", Service = each.key })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Listeners: one per distinct public port ----------------------------------
resource "aws_lb_listener" "https" {
  for_each = local.public_ports

  load_balancer_arn = aws_lb.this.arn
  port              = each.value
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn

  # TLS 1.3, and 1.2 as the floor. The default policy still permits TLS 1.0.
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  # The default action is a 404, not a forward. On a shared listener, traffic
  # that matches no rule belongs to no service; forwarding it to whichever
  # service happens to be the default is how one team's traffic reaches
  # another team's logs.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no service is registered for this host"
      status_code  = "404"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-https-${each.value}" })
}

resource "aws_lb_listener" "redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-http-redirect" })
}

# -----------------------------------------------------------------------------
# B. for_each over the FLATTENED nested map - one rule per service x port.
#
#   address -> aws_lb_listener_rule.this["api-8443"]
#
# Each rule indexes two other for_each resources by key: the listener for its
# port and the target group for its service. That is how a rule finds its
# partners without any positional coupling, and why removing port 8443 from api
# destroys exactly one rule.
# -----------------------------------------------------------------------------
resource "aws_lb_listener_rule" "this" {
  for_each = { for k, l in local.listeners : k => l if l.public }

  listener_arn = aws_lb_listener.https[tostring(each.value.port)].arn
  priority     = local.rule_priority[each.key]

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.value.service].arn
  }

  condition {
    host_header {
      values = ["${each.value.service}.${var.environment}.${var.domain}"]
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}", Service = each.value.service })
}
