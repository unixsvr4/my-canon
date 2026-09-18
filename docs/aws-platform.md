# AWS across the three labs

The repository's thesis is that the layers are what matter: **Terraform stops when the machine boots, Ansible owns what is inside it, tests decide when it is done, drift detection proves it stays that way.** AWS does not change any of that. It changes the tools in each slot, and it adds one constraint that on-premises does not have.

This page is the map: what exists in each lab, what is exercised by `make`, and what is reviewed but not run.

## The three handoffs

```text
lab 3  cloud-hosts.yml ──► out/aws/instances.auto.tfvars.json ──┐
       (the source of truth)                                     │
                                                                 ▼
lab 1  Terraform: ECS services, ALB, RDS, IAM, KMS  ──► resources, TAGGED
                                                                 │
                                    Environment / Role / Service / ManagedBy / KernelProfile
                                                                 │
                                                                 ▼
lab 2  inventory/aws_ec2.yml asks EC2 what exists ──► groups ──► baseline + kernel roles
       connection: Session Manager, not SSH
```

The tag set is the interface, and it is the only thing the three share. Terraform does not know the inventory exists; Ansible does not know Terraform created anything. Neither keeps a list of the other's resources, so **the two cannot disagree** — and the tag contract is asserted on all three sides:

| Side | Asserted by |
|---|---|
| Terraform stamps the tags | `terraform test`: mandatory tags on the database, a `Service` tag on every per-service resource, caller tags merging over rather than replacing |
| the source of truth renders them | 39 unit tests in lab 3, including one that the rendered tags produce the groups the playbooks target |
| Ansible groups on them | `make lab2-static` parses the plugin config; the group names in `out/aws/inventory-preview.yml` are the ones `group_vars/` files are named after |

That third link is the one worth guarding. A typo in a tag value means `--limit tag_Role_database` matches nothing, the play reports **"no hosts matched" and exits 0**, and a rollout that touched zero hosts looks exactly like success.

## What each lab adds

### Lab 1 — [`labs/lab1-terraform/aws/`](../labs/lab1-terraform/aws/)

The real implementation of the module the rest of lab 1 models with `local_file`: ECS Fargate services behind a shared ALB, RDS PostgreSQL, per-service IAM roles, one CMK, CloudWatch alarms and a dashboard. Same input contract, same five `for_each` patterns, same guard rails.

**22 `terraform test` runs against `mock_provider "aws"` — 18 plan-time, 4 apply-time, no credentials, no cost, 2.7 seconds.** Plus `terraform validate`, `tflint` with the provider-aware AWS ruleset, and `trivy` with four documented waivers and everything else a hard failure.

`envs/bootstrap/` solves the two chicken-and-egg problems: the S3 state backend with native locking, and **GitHub OIDC** so CI authenticates with no long-lived access key.

### Lab 2 — [`labs/lab2-ansible/inventory/`](../labs/lab2-ansible/inventory/)

`aws_ec2.yml` replaces the static host list. `group_vars/aws_ec2.yml` replaces SSH with Session Manager and Ansible Vault with Secrets Manager lookups. The roles are untouched — that is the point.

The `kernel` role gains an AWS-specific piece of judgement rather than an AWS-specific code path; see the constraint below.

`labs/lab2-ansible/aws/` is a second, separate root: four EC2 instances, one per distribution family, for proving the **kernel role's boot-argument layer** on the hardware and the AMIs that run the workload. It is a throwaway test rig rather than part of the platform - no load balancer, no database, no NAT gateway - and it is the one place in this repository that uses SSH rather than Session Manager, for a stated reason (its whole job is to reboot four machines and watch them come back). About 0.07 USD an hour; no `make` target applies it.

### Lab 3 — [`labs/lab3-baremetal/cloud-hosts.yml`](../labs/lab3-baremetal/cloud-hosts.yml)

The second record type: machines that are declared rather than built. The renderer emits cloud-init user data, Terraform input, and the tag-contract preview. `scripts/ssm_hybrid_register.sh` registers **physical** servers into Systems Manager, so one control plane covers both halves of the fleet.

## The one constraint AWS adds

On a server in a rack, a change you make to the running host is the change. In an Auto Scaling group it is not: the next scale-out, instance refresh, spot interruption or AZ rebalance boots a fresh instance **from the AMI**, with none of it. The fleet then has two populations that behave differently under load, and the difference is invisible to any dashboard that aggregates them.

This is the same class of problem as a `%post` block in a kickstart — a one-time change that becomes permanent invisible drift — and it decides where each layer belongs:

| Layer | On-premises | On AWS |
|---|---|---|
| runtime sysctls, module options, limits | Ansible, on a schedule | Ansible **or** user data; both are fine because both can be re-asserted |
| the kernel profile itself | a group in the inventory | the **`KernelProfile` tag**, read into `kernel_profile` by the `aws_ec2` inventory's `compose`. Decided once, by the thing that creates the machine |
| **kernel boot arguments** | Ansible, then a scheduled reboot | **the AMI.** Image Builder runs the same role, reboots during the build, and `kernel_fail_on_reboot_required: true` makes an unfinished image a failed build |
| packages | the `patch` role, batched, with a health gate | the same for long-lived instances; a new AMI for an immutable fleet |
| configuration that must stay correct | Ansible, always | Ansible, always — plus SSM State Manager for enforcement |

So `inventory/group_vars/aws_ec2.yml` sets `kernel_manage_bootloader: false` for discovered instances, with the reasoning next to it. The role is the same code either way; what changes is **where in the lifecycle it runs**.

## Access, without SSH

The instances lab 1's module creates sit in private subnets with no public address and no inbound rule on port 22. Reaching them with SSH needs one of three things nobody wants: a bastion (another host to patch and harden, holding a key that opens the fleet), a VPN a hosted runner cannot use, or a public IP with port 22 open.

Session Manager removes the question. The agent polls **outbound** to the SSM endpoints, so there is no inbound rule at all; authorisation is IAM, the same identity that authorises everything else; and CloudTrail records every session and every command. There is no SSH key to distribute, rotate or lose.

The same mechanism appears twice more in this repository, which is why it is worth learning once: `aws ecs execute-command` for a shell in a running Fargate task (lab 1 configures the cluster to log those sessions to an encrypted, retained log group), and hybrid activations for physical servers (lab 3).

What it needs: the SSM agent (in every current Amazon Linux, Ubuntu and RHEL AMI), an instance profile with `AmazonSSMManagedInstanceCore`, a route to the endpoints — a NAT gateway, or interface endpoints for `ssm`/`ssmmessages`/`ec2messages` — and, for the Ansible connection plugin, an S3 bucket to stage module payloads. That bucket is the part people forget, and the error (`Failed to transfer module`) does not mention it.

## Identity: no long-lived keys anywhere

| | |
|---|---|
| **CI to AWS** | GitHub OIDC. The token is minted per job and lasts minutes. `envs/bootstrap` creates the provider and a **read-only plan role**, so a pull-request pipeline can run on every push without being able to change anything. |
| **The `sub` condition** | the thing people get wrong. Without it, **any repository on GitHub** can assume the role; with `repo:owner/name:*`, any branch or fork pull request can. `github_subjects` is validated to reject a bare `*`. |
| **Terraform to resources** | `assume_role` per environment, one AWS account per environment, so a mistake in dev physically cannot plan against prod — the credentials do not exist there. |
| **Ansible to instances** | IAM through Session Manager. No keys. |
| **Application to database** | `manage_master_user_password` puts the credential in Secrets Manager and **never in Terraform state**; the task definition carries the ARN. IAM database authentication is on, so the application can use a 15-minute token instead. |
| **Roles this platform creates** | a permissions boundary caps what they can ever be granted, including by a policy attached later. |

## What is actually run, and what is not

Being precise about this matters more than the feature list. `make ci` runs in about 25 seconds with no AWS account and no charges.

| Exercised by `make` | How |
|---|---|
| the AWS module's logic, end to end | 22 `terraform test` runs against mocks, including apply/update/remove/destroy |
| the module's syntax and provider correctness | `terraform validate`, `tflint` with the AWS ruleset |
| misconfiguration policy | `trivy config`, exit 1 on anything not waived in code |
| the rendered cloud-init user data | `cloud-init schema`, the real validator, in a container |
| the tag contract | 39 unit tests, one of which checks the groups the playbooks target |
| the dynamic inventory's configuration | `ansible-inventory --list` parses it (no credentials needed to parse) |
| **the kernel role's boot arguments taking effect** | `make lab2-vms-up lab2-kernel-reboot` - four real VMs rebooted, then a kernel upgrade and a re-apply. A `make` target, but deliberately not part of `make ci` or `make all`: about 15 minutes |

| Reviewed, not run | Why, and what would exercise it |
|---|---|
| `terraform apply` of `envs/dev` or `envs/prod` | it costs money and touches a real account. A nightly apply/destroy into a sandbox account is the missing gate; the cost table in the [AWS README](../labs/lab1-terraform/aws/README.md#cost-honestly) says what it would be. |
| `envs/bootstrap` | run once per account, by a human, with elevated credentials. |
| the `aws_ec2` inventory returning hosts | needs credentials and instances. Without them it returns an **empty group rather than an error**, which is worth knowing: "no hosts matched" is what a missing identity looks like. |
| the EC2 kernel rig (`labs/lab2-ansible/aws/`) | it creates billable instances. `validate`, `tflint` and `trivy` cover it; the first `apply` is the first time the AMI data-source filters resolve against a real account. The same test has been run to completion on four **local VMs** with real kernels, including a kernel upgrade, so what EC2 adds is the platform rather than the logic. |
| Session Manager connections | needs instances, an instance profile and the transfer bucket. |
| hybrid activation | needs an account and a physical server. The script is syntax-checked and its source-of-truth guard is exercised. |

Anything real-provider — API errors, eventual consistency, service quotas, provider-specific ForceNew attributes — is described rather than exercised. A mock accepts an invalid subnet id; AWS does not.

## Service mapping

For reading the local module next to the real one, and for the second-cloud exercise in [`platform-translation.md`](platform-translation.md).

| Local stand-in | AWS | Notes |
|---|---|---|
| `local_file.service` | `aws_ecs_task_definition` + `aws_ecs_service` | every apply cuts a new revision; the service pins the ARN, so a rollback is a revision number |
| `local_file.listener` | `aws_lb_target_group` + `aws_lb_listener` + `aws_lb_listener_rule` | three resources, three different `for_each` keys |
| `local_file.public_endpoint` | `aws_route53_record` (alias) | alias, not CNAME: no TTL to wait out, free to query, works at the zone apex |
| `local_file.runbook` | `aws_cloudwatch_metric_alarm` + `aws_cloudwatch_dashboard` | `for_each` over the service resource, so a new service cannot be unmonitored |
| `local_file.stateful_store` | `aws_db_instance` | its own root in production, with its own apply approval |
| local state | S3 with `use_lockfile` and a CMK | a plan needs `s3:PutObject`/`DeleteObject` for the lock object |
| `drift-check.sh` | the same, plus AWS Config rules and Security Hub | Config answers "was it ever non-compliant", which a plan cannot |
| the six containers | EC2 instances, found by tag | same roles, same groups |
| `tamper.sh` | a console change someone made at 3am | the thing both drift checks exist for |
