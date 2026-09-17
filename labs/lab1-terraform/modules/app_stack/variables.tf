# -----------------------------------------------------------------------------
# variables.tf - the module's input contract.
#
# Rules this file follows:
#   1. Required inputs have NO default. A caller must not be able to silently
#      get the wrong environment, the wrong prefix, or an empty service map.
#   2. Optional inputs default to the SAFE value, not the convenient one
#      (deletion_protection = true).
#   3. Types are precise (object with optional() attributes, not `any`), so a
#      typo in a caller's tfvars fails at plan instead of producing a resource
#      with a silently-missing setting.
#   4. `validation` blocks reject bad input with a message that says what is
#      wrong and how to fix it - the error a reviewer sees in the PR.
# -----------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. canon-dev. Lowercase, digits and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name_prefix))
    error_message = "name_prefix must be 3-31 chars of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. Drives guard rails (see the prod preconditions in main.tf)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# THE for_each INPUT.
#
# A map keyed by service name - not a list. The key becomes part of every
# resource address, e.g. local_file.service["api"]. Because the address is the
# NAME rather than a position, adding or removing one service never touches the
# others. (With a list and `count`, removing element 0 shifts every index and
# Terraform destroys and recreates everything after it - see
# examples/01-count-vs-for-each for that failure, reproduced.)
#
# optional(type, default) (Terraform 1.3+) lets callers omit attributes that
# have a sensible default, while the type still rejects unknown attributes.
variable "services" {
  description = "Services to deploy, keyed by service name."
  type = map(object({
    image         = string
    cpu           = number
    memory        = number
    desired_count = optional(number, 1)
    public        = optional(bool, false)      # filtered for_each: only public services get an endpoint
    ports         = optional(list(number), []) # nested for_each: one listener per service x port
  }))

  validation {
    condition     = length(var.services) > 0
    error_message = "services must contain at least one service."
  }

  # Image tags must be explicit. ":latest" (or no tag) makes two applies of the
  # same commit deploy different code - drift you created yourself.
  validation {
    condition = alltrue([
      for name, svc in var.services :
      can(regex("^[a-z0-9./-]+:[A-Za-z0-9._-]+$", svc.image)) && !endswith(svc.image, ":latest")
    ])
    error_message = "every service image needs an explicit, immutable tag (name:1.2.3), never :latest or untagged."
  }

  validation {
    condition = alltrue(flatten([
      for name, svc in var.services : [for p in svc.ports : p >= 1 && p <= 65535]
    ]))
    error_message = "every port must be between 1 and 65535."
  }

  # Listener keys are "service-port" (see local.listeners in main.tf). A port
  # listed twice would produce a duplicate for_each key - catch it here, with a
  # message, instead of as "Duplicate object key" from inside the module.
  validation {
    condition     = alltrue([for name, svc in var.services : length(distinct(svc.ports)) == length(svc.ports)])
    error_message = "a service lists the same port twice; ports must be unique per service."
  }
}

variable "tags" {
  description = "Caller tags, merged over the module's mandatory tag contract (see locals in main.tf)."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Protect stateful resources. Defaults to the safe value; dev roots opt out explicitly."
  type        = bool
  default     = true
}
