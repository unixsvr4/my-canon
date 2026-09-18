# -----------------------------------------------------------------------------
# variables.tf - what this root takes from outside.
#
# The network inputs have lab defaults so the root can be initialised,
# validated and linted with no AWS account. In a real repository they would be
# `terraform_remote_state` data sources reading the network root's outputs, or
# SSM parameters that root publishes - and then a plan cannot be run against a
# VPC that does not exist.
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region for this environment."
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC from the network root."
  type        = string
  default     = "vpc-0123456789abcdef0"
}

variable "private_subnet_ids" {
  description = "Private subnets for tasks and the database, one per AZ."
  type        = list(string)
  default     = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer, one per AZ."
  type        = list(string)
  default     = ["subnet-0bbbbbbbbbbbbbbb1", "subnet-0bbbbbbbbbbbbbbb2"]
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listeners."
  type        = string
  default     = "arn:aws:acm:us-east-1:111122223333:certificate/00000000-0000-0000-0000-000000000000"
}

variable "hosted_zone_id" {
  description = "Route 53 zone for public records."
  type        = string
  default     = "Z0123456789ABCDEFGHIJ"
}

variable "domain" {
  description = "Parent domain: <service>.<environment>.<domain>."
  type        = string
  default     = "canon.example"
}

variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs, owned by the logging account."
  type        = string
  default     = "canon-alb-logs-dev"
}

variable "services" {
  description = "Services to deploy. Set in terraform.tfvars - this is the file a change request edits."
  type = map(object({
    image         = string
    cpu           = number
    memory        = number
    desired_count = optional(number, 1)
    public        = optional(bool, false)
    ports         = optional(list(number), [])
    health_path   = optional(string, "/healthz")
  }))
}

variable "tags" {
  description = "Tags merged over the module's mandatory contract."
  type        = map(string)
}
