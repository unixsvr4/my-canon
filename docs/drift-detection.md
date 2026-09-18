# Drift detection

Drift is any difference between what is running and what the code says. It occurs at two layers, which need two detectors, and both need the same things around them: a trustworthy signal, a record, and a remediation policy.

## Two layers

| | Infrastructure layer | OS layer |
|---|---|---|
| Examples | security group edited in a console; instance resized by hand | `sshd_config` edited at 2 a.m.; a package upgraded by hand; a sysctl changed |
| Detector | `terraform plan -detailed-exitcode` | `ansible-playbook site.yml --check --diff` |
| Definition of correct | the Terraform configuration | the baseline role |
| Native exit code for drift | **2** | **none** — `--check` exits **0** when it finds drift |
| Lab | `labs/lab1-terraform/drift-check.sh` | `labs/lab2-ansible/drift-check.sh` |

Terraform can't see inside a machine, and Ansible has no state to diff resources against. A platform needs both.

## What a plan can't see

`terraform plan` only compares attributes the provider reads back, for resources in state. Two kinds of drift are invisible to it — Lab 1 reproduces both:

| Blind spot | In the lab | On a cloud | Caught by |
|---|---|---|---|
| an attribute the provider doesn't refresh | datastore file made world-writable: plan says *No changes*, apply leaves it | a console-added rule on a security group whose rules are separate resources; a manually attached IAM policy | `verify-env.py` `integrity`; fixed with `-replace` |
| an object that isn't in state at all | a hand-made `canon-prod-hotfix.json` beside the managed objects | an instance launched by hand in a managed subnet | `verify-env.py` `unmanaged`; delete it, or `import` it into code |

So the drift job runs two checks: the plan, and a verification of the live environment (`labs/lab1-terraform/verify-env.py`) that inspects the real objects and inventories what exists beyond state.

## Signal

A detector is only useful if a scheduler can act on its exit code.

| Exit | Terraform wrapper | Ansible wrapper |
|---|---|---|
| 0 | no changes | every host matches the baseline |
| 1 | plan error | **incomplete**: a host was unreachable or a task failed |
| 2 | drift | drift on at least one host |

Two decisions to call out:

- **Ansible needs a wrapper.** The script runs the play with the `ansible.posix.json` callback, counts `changed` per host, and supplies exit 2 itself. Alerting on `ansible-playbook`'s own exit code never fires on drift.
- **Incomplete beats drift.** A host that couldn't be checked isn't a host without drift. "Partially checked, looked fine" is exactly the report that hides a broken server.

## Record

Each finding is written as an **immutable record before anyone remediates**:

```text
drift-history/<root or fleet>/<UTC timestamp>/
    plan.txt / drift.txt      human-readable diff, for a ticket
    plan.json / drift.json    machine-readable, for policy engines and reporting
drift-history/index.csv       one row per event
```

- **It survives remediation.** Re-applying the code fixes the environment. Without a record it also erases the answers to *what changed, when was it noticed, how long was it that way*, and in a regulated environment those are the questions that matter.
- **Read-only on write**, and never overwritten: two runs in the same second get `-2`, `-3` suffixes.
- **No binary plan by default.** A `.tfplan` is valid only against the state serial that produced it and holds every attribute in the clear, so it is a short-retention pipeline artifact, not part of a permanent record.
- **No local paths in records.** Ansible reports a controller temp path as the "after" header for template diffs, and the viewer replaces it with the destination file and template name.

## Remediation policy

| Drift looks like | Response |
|---|---|
| accidental (a hand edit, a debugging change left behind) | re-apply the code; link the record to the ticket |
| deliberate (someone needed something the code doesn't provide) | treat it as a **bug report against the module or role**: fix the code, then re-apply |
| security-relevant (`PermitRootLogin`, sudoers, firewall) | enforce immediately; investigate who and why from the record |
| recurring on the same hosts | find the root cause (a cron job, another tool, a missing role feature) |

Prevention is cheaper than detection: humans get read-only console access in production, day-to-day changes go through code, and the baseline enforces on a schedule for settings that must never differ.

## Scheduling

- Terraform: a scheduled plan per root (or Spacelift drift detection with optional reconciliation), and exit 2 opens a ticket linking the record.
- Ansible: `drift-check.sh` per environment on a schedule; enforcement runs separately for security baselines.
- Windows: `Test-DscConfiguration` provides the same signal natively for DSC-managed configuration.

## A third layer: the kernel

The two drift checks in this repository compare code with reality at the infrastructure layer (`terraform plan`) and the OS-configuration layer (`ansible-playbook --check`). Kernel tuning needs a third comparison, because a file being correct is not the same as the kernel running it, and neither of the first two can see the difference:

| What is compared | By what | What it misses |
|---|---|---|
| state vs. the provider's view | `terraform plan -detailed-exitcode` | anything the provider does not read back (`RESEARCH.md` T13), and anything not in state |
| the role's intent vs. the files | `ansible-playbook --check --diff` | a file that is right while the running configuration is not |
| **desired vs. the RUNNING kernel** | `roles/kernel/tasks/verify.yml` reading `/proc/cmdline`, `/proc/sys`, `/sys` | nothing at this layer — but it needs three outcomes, not two |

The three outcomes matter because collapsing them produces a check nobody trusts:

- **active** — configured and running. Fine.
- **pending** — configured, needs a reboot. A **report**: the automation did its job and the reboot is a scheduling decision. Treating this as a failure means a red check on every host between a tuning change and its maintenance window.
- **differs** — loadable at runtime, written, loaded, and *still* not the running value. A **failure**: something later in sysctl's read order owns that key, and nobody knows it.

The same distinction exists on AWS in a place people meet before they meet kernel tuning: an RDS parameter group. `apply_method = "immediate"` takes effect now; `pending-reboot` is written, accepted, and does nothing until the instance restarts. Setting a static parameter with `immediate` is accepted by Terraform *and* by the API, so `terraform apply` succeeds, the console shows the value as pending, and the database is still running the old one. It is the same shape as a boot argument, and it is why `labs/lab1-terraform/aws/modules/app_stack/database.tf` marks each parameter explicitly.
