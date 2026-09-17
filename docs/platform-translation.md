# Platform translation

The patterns in this repository are tool-agnostic. This page maps them onto platforms an infrastructure automation team commonly also runs.

## Spacelift

Spacelift is an IaC orchestration platform (Terraform/OpenTofu, Ansible, Pulumi, CloudFormation, Kubernetes). It productizes the pipeline described in `terraform-patterns.md`.

| Built by hand in this repo / a typical CI setup | Spacelift equivalent |
|---|---|
| one pipeline per Terraform root | a **stack**: repo + path + branch + backend + settings |
| directory per environment + per-root credentials | stacks per environment, grouped into **spaces** with RBAC |
| OPA/conftest on plan JSON | **plan policies** (Rego) |
| manual approval before a prod apply | **approval policies** |
| path filters deciding which roots run on a commit | **push policies** |
| "after the network root, run the app root" | **trigger policies** / stack dependencies |
| `drift-check.sh` on a schedule | scheduled **drift detection**, optionally reconciling through a normal tracked run |
| shared tfvars / CI secrets | **contexts** attached to stacks |
| S3 backend with `use_lockfile` | Spacelift-managed state, or keep your own backend |
| a self-hosted runner inside the network | **private worker pools**, which is how on-prem vCenter or a datacenter network is reached |
| module git tags | the module registry, with module tests |

The design questions don't change: how roots are split by blast radius, what a plan policy refuses, how one module version is promoted through environments.

## Alibaba Cloud

The pattern for any second cloud: keep the **module interface** identical (inputs, outputs, naming and tag contract, environment layout) and write a **per-cloud implementation** behind it. Don't build one module that abstracts every cloud; it becomes the lowest common denominator plus a pile of conditionals.

| AWS | Alibaba Cloud |
|---|---|
| EC2 | **ECS** (Elastic Compute Service); note the name clash with AWS ECS |
| EKS / ECS | **ACK** (Container Service for Kubernetes) / SAE |
| ECR | **ACR** |
| S3 | **OSS** |
| ALB / NLB / CLB | ALB / NLB / CLB (formerly SLB) |
| VPC / subnet | VPC / **VSwitch** (zonal) |
| IAM | **RAM** |
| Route 53 | Alibaba Cloud DNS / PrivateZone |
| RDS | ApsaraDB RDS |
| CloudWatch | CloudMonitor, SLS (Log Service) |
| KMS / Secrets Manager | KMS / Secrets Manager |
| Terraform `aws` provider | Terraform `alicloud` provider |

Differences that can't be abstracted away: RAM's policy model, zonal VSwitch design, uneven regional service availability, and mainland-China requirements (separate accounts and endpoints, ICP filing). Ansible barely changes, because inside the instance it's the same Linux.

## VMware vSphere

- **Terraform**: `vsphere_virtual_machine` cloned from a template, with datacenter, cluster, datastore, resource pool and port group as data sources; disk and NIC blocks; guest customization for hostname and IP. Module structure and state handling are unchanged. Differences: the provider is slower and chattier against vCenter, and a template refresh is a fleet-wide input change to roll out deliberately.
- **Ansible**: a vCenter dynamic inventory keyed on tags; `community.vmware` for snapshot-before-patch; the same roles inside the guest as on physical hosts.
- **Patching**: a pre-patch snapshot is the rollback path for VMs (the patch role's pre-flight assertion), removed after the health gate passes so snapshots don't accumulate and degrade datastore performance.

## Windows

The build pipeline mapping (WDS/MDT, `Autounattend.xml`, driver packs, DSC) is in [`labs/lab3-baremetal/windows/`](../labs/lab3-baremetal/windows/). For configuration and patching:

| Linux (this repo) | Windows |
|---|---|
| SSH + key + `become` | WinRM over HTTPS (5986) + Kerberos; not Basic, not CredSSP |
| `package`, `template`, `service` | `ansible.windows.win_package`, `win_template`, `win_service` |
| `dnf` in `serial` batches | `win_updates` + `win_reboot`; smaller batches, since reboots are required far more often |
| `--check --diff` for drift | Ansible check mode, or `Test-DscConfiguration` |
| a role reimplementing everything | `win_dsc` to call existing DSC resources where they are good |
| — | the **double-hop** problem: Kerberos constrained delegation, or a credential usable locally |
