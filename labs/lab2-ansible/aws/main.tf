# -----------------------------------------------------------------------------
# main.tf - four EC2 instances, one per distribution family, for proving the
# kernel role's boot-argument layer on REAL AWS hardware.
#
#   terraform init && terraform apply -var 'ssh_ingress_cidr=203.0.113.4/32'
#   cd .. && tests/kernel-reboot.sh --inventory inventory/kernel-aws.yml
#   terraform destroy
#
# THIS COSTS MONEY. Four t4g.small on demand is about 0.067 USD an hour in
# us-east-1, plus 4 x 20GB of gp3 at about 0.0022 USD an hour. Call it
# 0.07 USD an hour, or under a dollar for an afternoon - and nothing if you
# remember `terraform destroy`. The outputs print the running cost so it is on
# screen rather than in a bill.
#
# WHY THIS EXISTS WHEN THE VMs ALREADY PASS
#
# The QEMU VMs in ../vms/ prove the mechanism on a real kernel. What they cannot
# prove is the mechanism on the machines that actually run the workload, and
# three of those differences matter:
#
#   - Amazon Linux 2023 on Graviton is where AL2023 belongs. Its arm64 KVM
#     image needed two QEMU workarounds to boot locally at all (RESEARCH.md
#     A29); on EC2 it is simply the platform.
#   - The AMI's own boot arguments are not a cloud image's. `console=`,
#     `nvme_core.io_timeout`, the root device naming - the role has to merge
#     with whatever AWS's AMI shipped, not with what a generic cloud image did.
#   - `reboot-instances` is not `systemctl reboot`. An EC2 reboot goes through
#     the hypervisor, and "did it come back with the arguments" is the question
#     an instance refresh will ask later.
#
# It is DELIBERATELY NOT the app_stack module in lab 1. This is a throwaway test
# rig: no load balancer, no database, no NAT gateway (the instances sit in a
# public subnet with a public IP, which costs nothing, instead of paying ~32 USD
# a month for a NAT gateway to reach the package mirrors).
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Repository = "my-canon-kernel"
      Root       = "lab2-ansible/aws"
      Purpose    = "kernel-role-reboot-test"
    }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- The AMIs -----------------------------------------------------------------
#
# Every one of these is found by QUERY rather than pinned to an id, because an
# AMI id is region-specific and goes stale. Two are read from AWS's own public
# SSM parameters, which is the mechanism AWS documents for exactly this, and
# two from an owner + name filter with most_recent.
#
# All four are free AMIs. RHEL's own AMI carries a per-hour charge on top of the
# instance, and SLES's likewise, so this uses their free rebuilds - AlmaLinux
# for RHEL 9 (a bit-for-bit rebuild, same grubby/BLS mechanism) and openSUSE
# Leap for SLES 15 (same GRUB mechanism, same os_family "Suse"). The role's
# per-family implementation is selected from `ansible_facts['os_family']`, so
# these exercise the same code paths a paid AMI would.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "aws_ami" "almalinux" {
  most_recent = true
  owners      = ["764336703387"] # AlmaLinux OS Foundation

  filter {
    name   = "name"
    values = ["AlmaLinux OS 9*aarch64*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

data "aws_ami" "opensuse" {
  most_recent = true
  owners      = ["679593333241"] # openSUSE

  filter {
    name   = "name"
    values = ["openSUSE-Leap-15-6-*-hvm-ssd-arm64*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

locals {
  # name => { ami, login user, kernel profile }
  #
  # The PROFILE IS A TAG, and that is the integration worth noticing: the
  # dynamic inventory (../inventory/aws_ec2.yml) reads `tags.KernelProfile`
  # into `kernel_profile`, so the workload posture is decided here, once, in
  # the thing that creates the machine. Nothing else keeps a copy.
  #
  # The profiles match the VM lab host-for-host, so the two runs are comparable.
  instances = {
    rhel = {
      ami           = data.aws_ami.almalinux.id
      user          = "ec2-user"
      profile       = "database"
      isolated_cpus = "1"
    }
    ubuntu = {
      ami           = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
      user          = "ubuntu"
      profile       = "throughput"
      isolated_cpus = "1"
    }
    suse = {
      ami           = data.aws_ami.opensuse.id
      user          = "ec2-user"
      profile       = "low-latency"
      isolated_cpus = "1"
    }
    amazon = {
      ami           = nonsensitive(data.aws_ssm_parameter.al2023.value)
      user          = "ec2-user"
      profile       = "container-host"
      isolated_cpus = "1"
    }
  }
}

# --- Access -------------------------------------------------------------------
#
# SSH from ONE address, with a key generated locally by ../vms/up.sh.
#
# That is a deliberate departure from the rest of this repository, which reaches
# EC2 over Session Manager (../inventory/group_vars/aws_ec2.yml explains why: no
# inbound rule, no bastion, no key, IAM for authorisation). SSM is the right
# answer for a fleet. This is a throwaway rig whose entire job is to reboot four
# machines and watch them come back, and the SSM connection plugin needs an S3
# transfer bucket and handles a reboot less predictably - so the test rig uses
# the simple, reliable path and says so.
#
# var.ssh_ingress_cidr has NO DEFAULT. Leaving it open to the internet would be
# one forgotten variable away, so Terraform refuses to plan without it.
resource "aws_key_pair" "test" {
  key_name_prefix = "canon-kernel-test-"
  public_key      = file(var.ssh_public_key_path)
}

resource "aws_security_group" "test" {
  name_prefix = "canon-kernel-test-"
  description = "Kernel role reboot test rig: ssh from one address"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "canon-kernel-test" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.test.id
  description       = "ssh from the operator's address only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_ingress_cidr
}

# Outbound 443 and 80 for the package mirrors, which the kernel upgrade in
# phase 4 of the test needs.
#
# WAIVER: trivy AVD-AWS-0104 flags egress to 0.0.0.0/0. A package mirror is a
# CDN with no stable address range, and pinning one would break the test on a
# different day. It is two ports, outbound, from a throwaway rig.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.test.id
  description       = "package mirrors over TLS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.test.id
  description       = "package mirrors that still use plain http"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# --- The instances ------------------------------------------------------------
resource "aws_instance" "test" {
  for_each = local.instances

  ami                    = each.value.ami
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.test.id]
  key_name               = aws_key_pair.test.key_name

  # A public IP instead of a NAT gateway. The instances need to reach package
  # mirrors for the kernel upgrade, and a NAT gateway costs about 32 USD a
  # month plus data - more than this entire test, several times over, for a rig
  # that lives for an hour. The security group has one inbound rule, from one
  # address.
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    # A throwaway rig: the volume goes when the instance goes.
    delete_on_termination = true
  }

  # IMDSv2 only. The v1 endpoint is the one an SSRF in an application turns into
  # credential theft, and there is no reason for a new instance to allow it.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # The tag contract, and the reason there is no per-host configuration
  # anywhere: ../inventory/aws_ec2.yml turns KernelProfile into the role's
  # kernel_profile, and Role/Environment/Service into groups.
  tags = {
    Name          = "canon-kernel-${each.key}"
    Environment   = "dev"
    Role          = each.key
    Service       = "kernel-test"
    ManagedBy     = "terraform"
    KernelProfile = each.value.profile
    LoginUser     = each.value.user
    IsolatedCpus  = each.value.isolated_cpus
  }

  lifecycle {
    precondition {
      condition     = can(regex("^t4g\\.|^m[67]g\\.|^c[67]g\\.|^r[67]g\\.", var.instance_type))
      error_message = "This rig uses arm64 AMIs, so the instance type must be a Graviton family (t4g/m6g/m7g/c6g/c7g/r6g/r7g)."
    }
  }
}
