# -----------------------------------------------------------------------------
# outputs.tf - the module's public interface.
#
# Callers depend on outputs, not on internal resource addresses, so internals
# can be refactored (with `moved` blocks) without breaking anyone. Outputs are
# MAPS keyed like the input: a list output from a for_each resource has an order
# nobody should rely on, and it silently reshuffles when a key is added.
#
# These four mirror ../../../modules/app_stack exactly, so a consumer written
# against the local teaching module reads the real one unchanged.
# -----------------------------------------------------------------------------

output "service_names" {
  description = "Service key => ECS service name."
  value       = { for key, svc in aws_ecs_service.this : key => svc.name }
}

output "listeners" {
  description = "Listener key (service-port) => port. Shows the flattened composite keys."
  value       = { for key, l in local.listeners : key => l.port }
}

output "public_endpoints" {
  description = "Public service => FQDN. Empty map when nothing is public."
  value       = { for key, r in aws_route53_record.public : key => r.fqdn }
}

output "task_definition_arns" {
  description = "Service => task definition ARN, revision included. What deploy tooling and a rollback refer to."
  value       = { for key, td in aws_ecs_task_definition.this : key => td.arn }
}

# The AWS analogue of the local module's `deploy_ids`: a per-service value that
# changes if and only if THAT service's definition changed.
#
# It is a digest of the rendered definition, not the ARN, and the difference
# matters twice. The revision number is assigned by AWS, so it is unknown until
# apply and is not comparable in a mocked test (a mock does not model
# force-replacement, so an ARN it generated once never moves). The digest is
# computed by Terraform from the configuration, so it is exact in a test and
# still exact in production - and it is what CI can compare to answer "did this
# commit actually change the api service?" without calling AWS at all.
output "task_definition_digests" {
  description = "Service => digest of its rendered task definition. Changes only when that service's definition changes."
  value       = { for key, td in aws_ecs_task_definition.this : key => md5(td.container_definitions) }
}

# --- AWS-specific outputs the next root needs ---------------------------------

output "cluster_name" {
  description = "ECS cluster name, for deploy tooling and `aws ecs execute-command`."
  value       = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  description = "Load balancer hostname. Public records alias to this."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "Load balancer ARN suffix, the dimension CloudWatch metrics are keyed on."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arns" {
  description = "Service => target group ARN, for external health checks and canary tooling."
  value       = { for key, tg in aws_lb_target_group.this : key => tg.arn }
}

output "task_role_arns" {
  description = "Service => runtime role ARN. A service's own policies are attached to this, not to the shared execution role."
  value       = { for key, role in aws_iam_role.task : key => role.arn }
}

output "log_group_names" {
  description = "Service => CloudWatch log group."
  value       = { for key, lg in aws_cloudwatch_log_group.service : key => lg.name }
}

output "security_group_ids" {
  description = "The stack's security groups, for rules owned by other roots (a bastion, a monitoring collector)."
  value = {
    alb      = aws_security_group.alb.id
    task     = aws_security_group.task.id
    database = aws_security_group.database.id
  }
}

output "db_endpoint" {
  description = "Database endpoint, host:port."
  value       = aws_db_instance.this.endpoint
}

# The ARN, never the value. The secret's content is fetched at task start by the
# ECS agent; nothing here, and nothing in the state file, holds the password.
output "db_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credential."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "kms_key_arn" {
  description = "The stack's CMK, for roots that need to grant use of it."
  value       = aws_kms_key.this.arn
}
