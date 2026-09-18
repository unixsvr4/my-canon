# -----------------------------------------------------------------------------
# variables.tf - what this root takes from outside.
#
# Same file as ../dev/variables.tf, plus the three inputs only prod supplies:
# an alarm topic, a permissions boundary, and a narrowed public CIDR list.
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
  default     = "canon-alb-logs-prod"
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

variable "alarm_topic_arn" {
  description = "SNS topic the alarms notify. Prod sets it; an alarm with no action is a dashboard."
  type        = string
  default     = "arn:aws:sns:us-east-1:444455556666:canon-prod-platform-alerts"
}

variable "permissions_boundary_arn" {
  description = "Boundary applied to every role this stack creates."
  type        = string
  default     = "arn:aws:iam::444455556666:policy/canon-workload-boundary"
}

variable "public_ingress_cidrs" {
  description = "CIDRs allowed to reach the public listeners. Prod is fronted by CloudFront, so this is not 0.0.0.0/0."
  type        = list(string)
  default     = ["120.52.22.96/27", "205.251.249.0/24", "180.163.57.128/26"]
}
