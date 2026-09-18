# The kernel role on real AWS

Four EC2 instances, one per distribution family, tuned by the **same role, the same profiles and the same test** as the containers and the local VMs. This is the third and last rung of the ladder:

| Rung | What it proves | Cost | Time |
|---|---|---|---|
| [containers](../setup-distros.sh) (`tests/kernel-multidistro.sh`) | the role writes the right file, in the right place, on four distributions | $0 | ~40s |
| [QEMU VMs](../vms/up.sh) (`tests/kernel-reboot.sh`) | a real kernel boots with those arguments, survives a reboot, and a re-apply lands them on a **new kernel** | $0 | ~15 min |
| **EC2** (this directory) | the same, on the hardware and the AMIs that actually run the workload | **~$0.07/hour** | ~20 min |

Each rung tests something the one below it cannot. The containers cannot reboot. The VMs can, but they boot generic cloud images on QEMU — and Amazon Linux 2023 on Graviton, the platform this whole repository targets, needed two QEMU workarounds to boot locally at all.

## What it costs

**This directory creates billable resources.** Four `t4g.small` on demand in `us-east-1` is about **$0.067/hour**, plus 4 × 20GB of gp3 at about **$0.0022/hour** — call it **$0.07/hour**, well under a dollar for an afternoon, and nothing at all once you destroy it.

`terraform output running_cost_usd_per_hour` prints it, so the number is on screen rather than in a bill. There is no NAT gateway on purpose: the instances sit in the default VPC's public subnet with a public IP, because a NAT gateway is ~$32/month plus data — several times the cost of this entire test — and all these instances need outbound for is a package mirror.

**No `make` target applies this.** It is a deliberate act, by you, with your credentials.

## Run it

```bash
cd labs/lab2-ansible/aws && terraform init
```

`ssh_ingress_cidr` has **no default**, so Terraform refuses to plan without it, and refuses `0.0.0.0/0` outright. A test rig does not need to be reachable from the internet:

```bash
terraform apply -var "ssh_ingress_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```

Render the inventory from state rather than copying addresses by hand — the machine that created the instances is the one that knows where they are:

```bash
terraform output -raw ansible_inventory > ../inventory/kernel-aws.yml
```

```bash
cd .. && tests/kernel-reboot.sh --inventory inventory/kernel-aws.yml
```

```bash
cd aws && terraform destroy
```

The test is the same four phases as the VM lab: apply and see the arguments **pending**, reboot and see them **active**, re-apply and see **nothing change**, then install a new kernel, boot into it, observe what survived, and re-apply.

## What is different about EC2, and why it is worth the dollar

**The AMI's own boot arguments are not a cloud image's.** AWS's AMIs ship their own command line — `console=ttyS0`, `nvme_core.io_timeout`, root device naming — and the role has to merge with *that*, preserving it, rather than with whatever a generic cloud image happened to set. The key-aware merge is the same code; the input it has to not break is different, and more realistic.

**A reboot is a hypervisor reboot.** `terraform output reboot_command` gives you the `aws ec2 reboot-instances` form, which is closer to what an instance refresh or a maintenance event does than `systemctl reboot` is. Both are worth trying; the test uses the OS path, and the output gives you the API one.

**Amazon Linux 2023 is on its own platform.** The role's `vars/distro-Amazon.yml` says boot arguments on a running Auto Scaling instance are the wrong place — the next instance refresh discards them, and the AMI is where they belong. These instances are standalone, so managing the bootloader is correct here, and the file that explains the ASG caveat is the one you read next to it.

**The tag drives the role.** Terraform stamps `KernelProfile` on each instance, and [`../inventory/aws_ec2.yml`](../inventory/aws_ec2.yml) reads it into `kernel_profile` via `compose`. So the workload posture of a host is decided once, by the thing that creates the host, and no playbook or group_vars file holds a second copy to drift from. The static inventory this rig renders carries the same value as data, for the same reason.

## Access: SSH here, SSM in production

The rest of this repository reaches EC2 over **Session Manager** — no inbound rule, no bastion, no key, IAM for authorisation and CloudTrail for the audit trail. [`../inventory/group_vars/aws_ec2.yml`](../inventory/group_vars/aws_ec2.yml) is that configuration, and it is the right answer for a fleet.

This rig uses SSH from a single address instead, and the reason is narrow: its entire job is to reboot four machines and watch them come back, and the `aws_ssm` connection plugin needs an S3 transfer bucket and handles a reboot less predictably. A throwaway rig gets the simple, reliable path — with one inbound rule, from one `/32`, on instances that exist for an hour.

Saying which mechanism is for which purpose, and why, is the point. Using SSH everywhere because it is easier would not be.

## What is checked for free

Everything except the apply, which is why this can live in the repository without anyone spending money to review it:

```bash
terraform validate && tflint --config=../../lab1-terraform/aws/.tflint.hcl && trivy config .
```

`make tf-scan` covers it: that target scans **both** Terraform trees, because a scan that stops at one directory is a gate with a hole in it — which is what it was until this rig was added. Two `trivy` findings are waived in code with the reason next to them: outbound 80 and 443 to `0.0.0.0/0`, because a package mirror is a CDN with no stable address range and pinning one would break the test on a different day.

One thing that *can* be checked without an apply, and was: the inventory template in `outputs.tf` was rendered offline with placeholder instance data - the `%{for}` loop expanded by hand in Python - and the result parsed as YAML and inspected. It produces the `kernel_tuned` group `kernel.yml` targets, `ansible_connection: ssh`, and the right per-host `kernel_profile`, `ansible_user` and machine sizes. A templated YAML document that only ever renders during a billable apply is worth proving out some other way first.

The one gap worth stating plainly: **nobody has applied this.** The Terraform is valid, linted, scanned, and the AMI data sources are the ones AWS documents — but the first `apply` is the first time the AMI filters resolve against a real account, and an AMI owner or name pattern can change. If `data.aws_ami.opensuse` finds nothing, that is the thing to look at first.
