# -----------------------------------------------------------------------------
# variables.tf - the input contract.
#
# This is deliberately the SAME contract as ../../../modules/app_stack (the $0
# local version): name_prefix, environment, services, tags, deletion_protection.
# The local module is the teaching stand-in; this one is the real thing. Keeping
# one interface is the point - a caller's tfvars move between them unchanged,
# and the for_each shapes being taught are identical.
#
# What is added here is everything a real deployment needs but must NOT own:
# the network, the certificate, the log bucket. A module that creates its own
# VPC cannot be deployed twice into one account, and it puts the network's
# lifecycle inside the app's blast radius. Those are inputs, produced by the
# network root and passed in.
# -----------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. canon-dev. Lowercase, digits and hyphens."
  type        = string

  validation {
    # 31 characters, because ALB target-group names are capped at 32 and this
    # module appends to the prefix. A limit that bites at apply time, in one
    # region, twenty minutes in, is a limit worth validating at plan time.
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name_prefix))
    error_message = "name_prefix must be 3-31 chars of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. Drives the prod guard rails (see the preconditions in main.tf)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# THE for_each INPUT - a map keyed by service name, not a list.
#
# The key becomes part of every resource address: aws_ecs_service.this["api"].
# Because the address is the NAME and not a position, adding or removing a
# service never touches its neighbours. With a list and `count`, removing
# element 0 shifts every index and Terraform replaces everything after it.
variable "services" {
  description = "Services to deploy on Fargate, keyed by service name."
  type = map(object({
    image         = string
    cpu           = number
    memory        = number
    desired_count = optional(number, 1)
    public        = optional(bool, false)      # filtered for_each: only public services get DNS
    ports         = optional(list(number), []) # nested for_each: one listener rule per service x port
    health_path   = optional(string, "/healthz")
  }))

  validation {
    condition     = length(var.services) > 0
    error_message = "services must contain at least one service."
  }

  # Image tags must be explicit. ":latest" makes two applies of the same commit
  # deploy different code - drift you created yourself. On ECS it is worse than
  # on most platforms: the task definition records the tag, so a task replaced
  # by the scheduler at 3am silently pulls whatever ":latest" means by then.
  validation {
    condition = alltrue([
      for name, svc in var.services :
      can(regex("^[a-zA-Z0-9./_:-]+:[A-Za-z0-9._-]+$", svc.image)) && !endswith(svc.image, ":latest")
    ])
    error_message = "every service image needs an explicit, immutable tag (repo:1.2.3 or repo@sha256:...), never :latest or untagged."
  }

  # Fargate only accepts specific cpu/memory pairs. The API rejects anything
  # else with "No Fargate configuration exists for given values" - a message
  # that names neither the service nor the valid options. Catch it in the PR.
  validation {
    condition = alltrue([
      for name, svc in var.services : contains([256, 512, 1024, 2048, 4096, 8192, 16384], svc.cpu)
    ])
    error_message = "Fargate cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }

  validation {
    condition = alltrue([
      for name, svc in var.services :
      svc.memory >= svc.cpu * 2 && svc.memory % 1024 == 0 || svc.cpu == 256 && contains([512, 1024, 2048], svc.memory)
    ])
    error_message = "Fargate memory must be at least 2x cpu and a whole number of GiB (256 cpu also allows 512/1024/2048 MiB)."
  }

  validation {
    condition = alltrue(flatten([
      for name, svc in var.services : [for p in svc.ports : p >= 1 && p <= 65535]
    ]))
    error_message = "every port must be between 1 and 65535."
  }

  # Listener-rule keys are "service-port" (see local.listeners). A port listed
  # twice would produce a duplicate for_each key - caught here with a message,
  # instead of as "Duplicate object key" from inside the module.
  validation {
    condition     = alltrue([for name, svc in var.services : length(distinct(svc.ports)) == length(svc.ports)])
    error_message = "a service lists the same port twice; ports must be unique per service."
  }

  validation {
    condition = alltrue([
      for name, svc in var.services : !svc.public || length(svc.ports) > 0
    ])
    error_message = "a public service with no ports has nothing to expose; give it ports or set public = false."
  }

  # The service KEY is not just a label: it is part of every resource name, the
  # DNS record, the log-group path and the target-group name_prefix (capped at
  # six characters by the ELB API - see locals in data.tf). Rejecting an
  # unusable key here beats a provider error on one resource out of forty.
  validation {
    condition     = alltrue([for name, svc in var.services : can(regex("^[a-z][a-z0-9-]{1,15}$", name))])
    error_message = "every service key must be 2-16 chars of lowercase letters, digits and hyphens, starting with a letter."
  }
}

# --- Inputs the module must not own -------------------------------------------

variable "vpc_id" {
  description = "VPC the tasks and load balancer live in. Owned by the network root, not by this module."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "private_subnet_ids" {
  description = "Private subnets for the Fargate tasks and the database. One per AZ."
  type        = list(string)

  validation {
    # Two AZs is the floor for an ALB and for RDS multi-AZ. A single-subnet
    # deployment survives until the day that AZ has an event.
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "give at least two private subnets, in different availability zones."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets for the internet-facing load balancer. One per AZ."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "give at least two public subnets, in different availability zones."
  }
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listeners. Issued and validated by the platform root."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 zone for public service records."
  type        = string
}

variable "domain" {
  description = "Parent domain for public records: <service>.<environment>.<domain>."
  type        = string
}

variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs. Lives in the logging account, owned by the logging root."
  type        = string
}

# --- Policy inputs ------------------------------------------------------------

variable "tags" {
  description = "Caller tags, merged over the module's mandatory tag contract (see locals in main.tf)."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Protect the database and the load balancer. Defaults to the safe value; dev roots opt out explicitly."
  type        = bool
  default     = true
}

variable "public_ingress_cidrs" {
  description = "CIDRs allowed to reach the public listeners. Narrow this for anything not genuinely public."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention. 0 means never expire, which is a cost and a compliance decision, so it is not allowed."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch accepts (1, 3, 5, 7, 14, 30, 60, 90, ... 3653)."
  }
}

variable "alarm_topic_arn" {
  description = "SNS topic the alarms notify. Null means the alarms exist but page nobody, which is a dashboard, not an alert."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the roles this module creates. Caps what they can ever be granted, including by a later policy change."
  type        = string
  default     = null
}

variable "db_engine_version" {
  description = "PostgreSQL major.minor for the database."
  type        = string
  default     = "17.4"
}

variable "db_instance_class" {
  description = "Database instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Database storage, GiB."
  type        = number
  default     = 20
}
