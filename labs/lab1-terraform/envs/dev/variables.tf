# -----------------------------------------------------------------------------
# Root variables mirror the module's inputs. The TYPE is repeated here on
# purpose: tfvars are validated at the root boundary, so an error message
# points at this environment's terraform.tfvars, not deep inside the module.
# -----------------------------------------------------------------------------

variable "services" {
  description = "Services for this environment, keyed by name (the module's for_each input)."
  type = map(object({
    image         = string
    cpu           = number
    memory        = number
    desired_count = optional(number, 1)
    public        = optional(bool, false)
    ports         = optional(list(number), [])
  }))
}

variable "tags" {
  description = "Environment-level tags (Owner, CostCenter, ...)."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Protect stateful resources."
  type        = bool
  default     = true
}
