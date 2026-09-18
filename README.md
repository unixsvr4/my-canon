# Infrastructure Automation: Terraform · AWS · Ansible · Bare Metal

Working, tested examples of how a hybrid infrastructure platform is **built, configured, changed safely, and kept honest**: physical servers from a MAC address to production, AWS and virtual resources with Terraform, fleet configuration and patching with Ansible, kernel tuning that survives a reboot on four distributions, and drift detection across both layers.

Prepared for the **canon** infrastructure automation engineering interview loop. Everything runs locally at **$0** — including the AWS code, which is apply-tested against a mocked provider.

```bash
make ci      # ~25s, no Docker, no cloud account: lint, validate, 38 terraform tests, 4 for_each demos, 39 unit tests
make all     # + apply/verify/tamper/destroy both Terraform envs; Docker: 6 hosts converged, idempotence, drift, rolling patch, kernel tuning on 4 distributions, real parsers
```

---

## What is here

| Lab | The engineering problem it answers |
|---|---|
| [**Terraform**](labs/lab1-terraform/) | How do you structure modules and environments so a change to one thing can't destroy its neighbours, and how do you recover when an apply fails halfway? |
| [**Terraform on AWS**](labs/lab1-terraform/aws/) | How do you apply-test real cloud infrastructure on every commit without an account or a bill — and what does that *not* prove? |
| [**Ansible**](labs/lab2-ansible/) | How do you write a role that is reused unchanged across a fleet, prove it is idempotent, and roll a risky change across hundreds of servers without an outage? |
| [**Kernel tuning**](labs/lab2-ansible/roles/kernel/) | How do you make a kernel setting survive a reboot on RHEL, Ubuntu, SUSE and Amazon Linux, when each stores boot arguments somewhere different — and how do you know it is actually in effect? |
| [**Bare metal + EC2**](labs/lab3-baremetal/) | How does a server get from a rack, or from an API call, to production with no decision made by a human at a console? |
| [**Drift**](docs/drift-detection.md) | How do you know, every day, that what's running is still what the code says, and keep the evidence after you fix it? |

## Highlights

**Terraform — `for_each` done properly** ([lab 1](labs/lab1-terraform/))

- A module that walks through `for_each` over a map of objects, a **flattened nested map** with composite keys (`api-443`), a **filtered map** (zero instances when nothing matches), and **another resource's instances**.
- Four runnable demos with measured results. Removing one list item with `count` replaces 2 resources and destroys 1; with `for_each` it destroys exactly 1. Positional keys inside `for_each` replaced 4 firewall rules just to *add* one CIDR. A `count` → `for_each` migration with **`moved` blocks: 3 moves, 0 changes, identical object ids**.
- **16 native `terraform test` runs**: 12 plan-time unit tests and 4 **apply-time integration tests** that create the stack, read every object back, change one service, remove one, replace the datastore, and destroy it. Every assertion **mutation-checked** (break the module and the test fails).
- **The environments are tested after apply, not just applied.** `verify-env.py` checks every live object exists, still matches state, is wired correctly and meets prod policy, and that nothing unmanaged sits beside it. `tamper-env.sh` proves it: a hand-scaled service, a world-writable datastore and a hand-made "hotfix" object all fail verification, and **two of the three survive a successful `terraform apply`** because `plan` can't see them.
- Two real bugs caught and fixed, each with a regression test: one shared `random_id` silently re-coupled every service, so removing one replaced all of them; and `create_before_destroy` on a fixed-name datastore made `-replace` **delete it while reporting success** — found by the post-apply verifier.

**Terraform on AWS — apply-tested on every commit, for nothing** ([lab 1 / aws](labs/lab1-terraform/aws/))

- The same module against the real `aws` provider: ECS Fargate behind a shared ALB, RDS with the master password **never in state**, per-service task roles, one CMK, alarms generated from the service resource. Same input contract as the $0 version, so the two read side by side.
- **22 `terraform test` runs against `mock_provider` — 18 plan-time and 4 apply-time — in 2.7 seconds with no credentials.** The apply runs assert what a plan cannot see: every listener rule lands on its own port's listener and its own service's target group, the credential arrives as a `secrets` reference and not in `environment`, and one CMK encrypts everything. All 11 mutations caught.
- **Three mock behaviours that cost an afternoon each, documented next to the code that works around them**: random ARNs fail the provider's format validation the moment a run becomes `apply`; a type-wide `mock_resource` default makes every per-key assertion pass vacuously; and a mock does not model force-replacement, so *"was this replaced?"* is not a question it can answer — which is why the isolation test compares Terraform-computed digests instead.
- `trivy` now has teeth: four findings, each **waived in the code with the reason in the diff**, everything else a hard failure. Keyless CI via GitHub OIDC, including the `sub` condition that otherwise lets any repository on GitHub assume the role.
- `create_before_destroy` appears twice in this repository with **opposite conclusions** — removed from the local datastore, required on the AWS target group — and the deciding question is the same one both times.

**Kernel tuning that survives a reboot, on four distributions** ([lab 2 / kernel](labs/lab2-ansible/roles/kernel/))

- One role, one interface, **four persistence mechanisms**: RHEL 9's BLS entries plus `grubby`, Ubuntu's `/etc/default/grub.d` drop-in, SUSE's `grub2-mkconfig`, and Amazon Linux's AMI lifecycle. Verified on AlmaLinux 9, Ubuntu 24.04, SLES 15 and Amazon Linux 2023 — **20 assertions that each got its own mechanism's artifact, and `changed=0` on the second run for all four.**
- **And it really does survive a reboot, watched rather than claimed.** Four QEMU virtual machines with their own kernels are tuned, rebooted, and re-checked from outside Ansible: every managed argument live in `/proc/cmdline`, transparent huge pages actually switched from `[always]` to `[never]`, the 1GB huge page actually reserved. Then a **real kernel upgrade** (AlmaLinux 5.14.0-427 → 5.14.0-687, Ubuntu 6.8.0-31 → 6.8.0-139), a re-apply, and every argument active again on the new kernel. The same role and the same test run against [four EC2 instances](labs/lab2-ansible/aws/).
- Three layers, because "set a sysctl" is three problems: runtime parameters, **load-time** options (`nf_conntrack`'s hash size can only be set as the module loads), and **boot arguments** (`transparent_hugepage=never` has no sysctl at all).
- **Removal works, not just addition.** A key-aware merge preserves the distribution's own boot arguments, replaces stale values instead of appending a second copy, and records what the role owns in a marker so that dropping a setting from a profile drops it from the boot line.
- It **reports what is not yet in effect** rather than claiming success: `PENDING` needs a reboot, `DIFFERS` means something silently overrode a runtime value and is a failure. On AWS it declines to manage boot arguments on a running Auto Scaling instance, because the next instance refresh would discard them.
- The check that earns its keep: a sysctl key this kernel does not have is refused, naming it. `net.ipv4.tcp_tw_recycle` was removed from Linux in 4.12 and is still in tuning guides; depending on the distribution `sysctl --system` skips it silently or **aborts the file**.
- Rebooting for real found **six bugs the container tests could not**, including two that only a genuine Amazon Linux host shows: AL2023 populates `GRUB_CMDLINE_LINUX_DEFAULT` where RHEL 9 populates `GRUB_CMDLINE_LINUX`, and `grubby --remove-args` **blanks the whole of `GRUB_CMDLINE_LINUX`** there — so the role was writing to the variable AL2023 ignores and then erasing it with its own next task, while the reboot test passed the whole time because `grubby` had done its half. All six are in [`RESEARCH.md`](RESEARCH.md).

**Ansible — a reusable, provably idempotent role** ([lab 2](labs/lab2-ansible/))

- `roles/baseline`: an input contract enforced by `argument_specs` + cross-field validation, the `_extra` merge pattern for layering group vars without clobbering defaults, `validate:` on sshd and sudoers writes, handlers that skip cleanly without systemd.
- **Idempotence proven, not claimed**: converge 6 hosts, second run `changed=0`. Six anti-patterns side by side with their fixes: the broken playbook changes **6 of 6** tasks on every run; ansible-lint catches only 5, and misses the timestamp entirely.
- **Verifies effective config, not files**: AlmaLinux 9 ships an sshd drop-in that silently overrides a `99-`-named hardening file. Every task succeeds, but `sshd -T` still shows `permitrootlogin yes`, and the role fails the host.
- Found and handled: `argument_specs` lets a bare YAML `no` through a `"no"`/`"yes"` choice list.
- A rolling patch that **stops itself after 3 of 6 hosts**, quarantines with diagnostics, and re-runs only the failures, including the subtle fix for `rescue`d failures not counting toward `max_fail_percentage`.

**Bare metal and EC2 — one source of truth, validated by the real parsers** ([lab 3](labs/lab3-baremetal/))

- `hosts.yml` → per-MAC kickstarts, DHCP reservations, and the **Ansible inventory that hands new servers to lab 2's roles**. `cloud-hosts.yml` → cloud-init user data, Terraform input, and the tag contract — machines that are *declared* rather than *built*, with the same roles applied afterwards.
- **The tag contract is tested offline.** Terraform stamps the tags, lab 2's `aws_ec2` inventory turns them into groups, and nothing checked that link — so a typo means `--limit tag_Role_database` matches nothing and the play exits 0. A rollout that touched zero hosts looks exactly like success. The renderer emits the groups the tags will produce, and a unit test asserts the playbooks' groups are among them.
- A validator that refuses duplicate MACs, gateways outside the subnet, one-member bonds, and more, reporting every error at once — plus **fleet-level rules** that catch what record-by-record review cannot: a hostname colliding across the two files (which caught a real collision in the fixture added for it), and a prod service with every instance in one availability zone.
- `cloud-init schema` joins `dhcpd -t` and `ksvalidator` as a real-parser gate. Valid YAML is not valid user data, and a file missing its `#cloud-config` first line is **silently ignored entirely** — the instance boots, passes its health check, and ran none of its configuration.
- `dhcpd -t` and `ksvalidator` in a container found **three real bugs** unit tests couldn't see: an undeclared DHCP option 93, a kickstart `network` line wrapped with `\` (kickstart has no line continuation, so the bond and VLAN would silently never be configured), and an invalid `%packages` flag.

**Drift at both layers, with evidence that outlives the fix**

- Terraform `plan -detailed-exitcode` and Ansible `--check --diff`, with one exit-code contract: **0 clean · 2 drift · 1 incomplete**. The Ansible wrapper exists because `--check` exits 0 when it finds drift.
- Each finding becomes an immutable, timestamped record (human diff + JSON) that survives remediation, with viewers that show `content.image: web:2.1.0 -> web:2.2.0` rather than raw JSON.

## Architecture

```mermaid
flowchart LR
    SOT[("Source of truth")] --> BM["Bare-metal pipeline<br/>Redfish · DHCP · iPXE · kickstart"]
    SOT --> TF["Terraform<br/>cloud & virtual resources"]
    BM -- generated inventory --> ANS["Ansible roles<br/>baseline · patch"]
    TF -- tags = inventory --> ANS
    ANS --> ACC["Acceptance tests"] --> PROD(["Production"])
    PROD --> DRIFT["Drift detection<br/>both layers"]
    DRIFT -- record + ticket --> SOT
```

**Terraform stops when the machine boots. Ansible owns what's inside it. Tests decide when it's done. Drift detection proves it stays that way.** Details: [`docs/architecture.md`](docs/architecture.md).

## Repository map

```text
.
├── Makefile                      # every check and demo; `make help`
├── .github/workflows/ci.yml      # calls the same make targets
├── docs/                         # design notes: architecture, patterns, drift, platforms
├── labs/
│   ├── lab1-terraform/           # module + envs + tests + for_each examples + drift tooling
│   │   └── aws/                  # the same module on real AWS, apply-tested with mock_provider
│   ├── lab2-ansible/             # baseline, kernel & patch roles, idempotence examples, tests, drift tooling
│   └── lab3-baremetal/           # source of truth (physical + cloud), renderers, iPXE/DHCP/kickstart, acceptance
└── RESEARCH.md                   # sources, verification log, and every bug found along the way
```

Every directory has a README explaining its part in detail.

## Documentation

| | |
|---|---|
| [Architecture](docs/architecture.md) | layer ownership, the Terraform/Ansible boundary, the handoffs |
| [Terraform patterns](docs/terraform-patterns.md) | modules, environments, `for_each` rules, state & locking, review pipeline, failed-apply recovery |
| [Ansible patterns](docs/ansible-patterns.md) | role design, idempotence, inventories, secrets, testing layers, patching at scale |
| [Bare-metal lifecycle](docs/bare-metal-lifecycle.md) | rack → production → decommission, latency-sensitive builds |
| [Drift detection](docs/drift-detection.md) | signals, exit codes, immutable records, remediation policy |
| [AWS platform](docs/aws-platform.md) | the three handoffs, the tag contract, identity without long-lived keys, and exactly what is run versus reviewed |
| [Platform translation](docs/platform-translation.md) | Spacelift, Alibaba Cloud, VMware vSphere, Windows |

## Verification

Every quoted result in the READMEs (command output, resource counts, exit codes, test totals) was produced by running the command next to it. `make all` re-runs the automated ones. [`RESEARCH.md`](RESEARCH.md) records the tool versions, the sources, and each bug found while building this, with how it was found and fixed.

The CI workflow calls the same `make` targets that were run locally. Its `static-and-unit`, `ansible` and `bare-metal` jobs have run green on GitHub-hosted runners; the `kernel` job is new and has only been run locally, so treat its first GitHub run as the check on runner-specific details — it pulls images from three registries, including SUSE's.

Two things are deliberately **not** run by any target, and are described rather than exercised: `terraform apply` against a real AWS account (it costs money — the [cost table](labs/lab1-terraform/aws/README.md#cost-honestly) says how much), and the AWS dynamic inventory and Session Manager connection returning real hosts (they need credentials). [`docs/aws-platform.md`](docs/aws-platform.md) has the full list of what is exercised and what is reviewed.

## License

[MIT](LICENSE)
