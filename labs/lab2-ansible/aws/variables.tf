variable "region" {
  description = "Region for the test rig. Any region with the default VPC intact."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Graviton instance type. t4g.small is enough for a kernel test and is the cheapest type with 2 vCPUs, which the low-latency profile's isolated core needs."
  type        = string
  default     = "t4g.small"
}

variable "ssh_ingress_cidr" {
  description = "The ONE address allowed to reach port 22. No default on purpose: `curl -s https://checkip.amazonaws.com` and pass it as /32."
  type        = string

  validation {
    # The whole point of this variable is that it is narrow. An accidental
    # 0.0.0.0/0 on a rig with four freshly-booted instances is exactly the
    # mistake worth making impossible.
    condition     = var.ssh_ingress_cidr != "0.0.0.0/0"
    error_message = "Refusing 0.0.0.0/0. Pass your own address as a /32 - `curl -s https://checkip.amazonaws.com`."
  }

  validation {
    condition     = can(cidrnetmask(var.ssh_ingress_cidr))
    error_message = "ssh_ingress_cidr must be valid CIDR, e.g. 203.0.113.4/32."
  }

  validation {
    condition     = tonumber(split("/", var.ssh_ingress_cidr)[1]) >= 24
    error_message = "Use a /24 or narrower. A test rig does not need to be reachable from a whole ISP."
  }
}

variable "ssh_public_key_path" {
  description = "Public key to install. Defaults to the key ../vms/up.sh generates, so the same key reaches the local VMs and these instances."
  type        = string
  default     = "/tmp/canon-kernel-vms/id_ed25519.pub"
}
