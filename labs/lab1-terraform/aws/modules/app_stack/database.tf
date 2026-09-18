# -----------------------------------------------------------------------------
# database.tf - E. No for_each, on purpose.
#
# A database is a singleton with its own lifecycle. Folding it into the services
# map would put stateful data one tfvars typo away from a destroy: remove a key
# from a map and Terraform deletes that instance, which is the correct behaviour
# for a stateless service and a resignation letter for a database.
#
# In a real platform this resource does not live in the application root at all.
# It lives in its own root, with its own state file and its own apply approval,
# so that "plan the app" can never print "1 to destroy" about the database.
# `prevent_destroy` only accepts a literal, so it cannot be driven by
# var.environment - the root split is the stronger control anyway.
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db"
  description = "Private subnets for ${var.name_prefix}"
  subnet_ids  = var.private_subnet_ids

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db" })
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-db"
  description = "PostgreSQL for ${var.name_prefix}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

# Only the tasks, and only 5432. No CIDR, no bastion rule: a rule referencing
# the task security group stays correct when subnets change and cannot be
# widened by someone adding an address range.
resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = aws_security_group.database.id
  description                  = "postgresql from the application tasks"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.task.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db-in-5432" })
}

# -----------------------------------------------------------------------------
# The parameter group: the database's equivalent of Lab 2's kernel tuning, and
# it has the same two-tier persistence problem.
#
#   apply_method = "immediate"     -> takes effect now (dynamic parameters)
#   apply_method = "pending-reboot" -> written now, ACTIVE AFTER A REBOOT (static)
#
# Setting a static parameter with "immediate" is accepted by Terraform and by
# the API, and then silently does nothing until the next maintenance window
# restarts the instance - so `terraform apply` succeeded, the console shows the
# new value as "pending-reboot", and the database is still running the old one.
# That is exactly the trap Lab 2's kernel_tuning role reports as "reboot
# required": the desired state and the RUNNING state are different things, and
# only one of them is what your workload experiences.
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg17"
  family      = "postgres17"
  description = "${var.name_prefix} ${var.environment} tuning"

  # Static: refuse non-TLS connections. Needs a reboot, and it is worth one.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Static: the extension must be loaded at server start.
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # Dynamic: log anything slower than 500ms. Takes effect immediately.
  parameter {
    name         = "log_min_duration_statement"
    value        = "500"
    apply_method = "immediate"
  }

  # Dynamic: log every connection that is not closed cleanly, and every DDL.
  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_statement"
    value        = "ddl"
    apply_method = "immediate"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-pg17" })

  # Changing a parameter group's parameters forces a new group, and an instance
  # cannot move off a group that is being deleted in the same apply.
  lifecycle {
    create_before_destroy = true
  }
}

# WAIVER: trivy AVD-AWS-0177 wants deletion_protection literally true. It is
# driven by var.deletion_protection, which DEFAULTS to true, and the
# precondition at the bottom of this resource refuses `prod` with it off - a
# stronger guarantee than a literal, because it cannot be switched off for prod
# in a hurry without the plan failing and saying why. dev opts out explicitly.
#
#trivy:ignore:AVD-AWS-0177
resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class
  db_name        = replace("${var.name_prefix}_app", "-", "_")

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 4 # storage autoscaling: full disks page people at 3am
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  port                   = 5432

  parameter_group_name = aws_db_parameter_group.this.name

  # The master password is generated and rotated by RDS into Secrets Manager.
  # This is the setting that keeps the credential OUT OF TERRAFORM STATE: with
  # `password = ...` the value is in the state file forever, in plaintext, and
  # anyone who can read the state bucket can read the database. The task
  # definition in main.tf consumes the secret ARN, never the value.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn
  username                      = "appadmin"

  iam_database_authentication_enabled = true

  multi_az                = var.environment == "prod"
  backup_retention_period = var.environment == "prod" ? 30 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true
  deletion_protection     = var.deletion_protection

  # A final snapshot is the difference between a mistake and an incident.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-db-final"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.this.arn
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db" })

  lifecycle {
    precondition {
      condition     = var.environment != "prod" || var.deletion_protection
      error_message = "deletion_protection must stay on in prod; dev and staging may opt out."
    }

    # The class is not just a cost decision: db.t*.micro has no Performance
    # Insights on some engines and no Multi-AZ headroom worth having.
    precondition {
      condition     = var.environment != "prod" || !can(regex("(micro|small)$", var.db_instance_class))
      error_message = "prod must not run on a ${var.db_instance_class}: pick at least a *.medium."
    }
  }
}
