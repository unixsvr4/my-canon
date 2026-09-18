# RESEARCH.md — sources, verification, and the bugs found along the way

This file makes the repository reproducible and auditable: which versions were used, where the design guidance comes from, how each result was verified, and every defect found while building it, including how it was found. A record of bugs caught is more useful than a claim that there were none.

## 1. Environment

| Tool | Version |
|---|---|
| macOS (Apple Silicon), Docker via OrbStack | Darwin 25.6, Docker 29.4.0 |
| Terraform | 1.16.1 (≥ 1.7 needed for `mock_provider`) |
| Terraform providers | hashicorp/aws 6.65.0, hashicorp/local 2.5.x, hashicorp/random 3.6.x |
| tflint / trivy / checkov | 0.61.0 / 0.74.0 / 3.3.10 |
| tflint rulesets | bundled terraform 0.14.1, tflint-ruleset-aws 0.44.0 |
| ansible-core / ansible-lint | 2.21.4 / 26.8.0 |
| Collections (pinned in `labs/lab2-ansible/requirements.yml`) | community.docker 5.3.0, ansible.posix 2.2.2, community.library_inventory_filtering_v1 1.1.5, amazon.aws 10.1.0, community.aws 10.1.0 |
| Python / PyYAML / jq / GNU Make | 3.14.7 / 6.0.3 / 1.8.2 / 3.81 |
| Lab host image | `almalinux:9` (AlmaLinux 9.8), aarch64 |
| Kernel-role containers | `almalinux:9` (9.8), `ubuntu:24.04`, `registry.suse.com/bci/bci-base:15.6` (SLES 15.6), `amazonlinux:2023` — all aarch64, all free to pull |
| Kernel-role VMs (real kernels) | QEMU 11.1.1 with `-accel hvf` and `edk2-aarch64-code.fd`, booting the distributions' own public cloud images: AlmaLinux 9.4 (kernel 5.14.0-427), Ubuntu 24.04 GA (6.8.0-31), openSUSE Leap 15.6 (6.4.0-150600), Amazon Linux 2023.12 (6.1.186) |
| Kernel-role EC2 rig | `labs/lab2-ansible/aws/`: 4 x t4g.small, AMIs resolved from AWS SSM public parameters and owner filters. **Validated, linted and scanned; not applied** |
| Target interpreters | python3 3.9.25 (AlmaLinux, Amazon), 3.12.3 (Ubuntu), **3.11.14 (SLES — its own python3 is 3.6.15, which ansible-core cannot use)** |
| Real-parser checks (in container) | ISC `dhcp-server`, `pykickstart` and `cloud-init` from AlmaLinux 9 repositories |

## 2. Sources

**Terraform**
- `for_each`, `count`, and "Invalid for_each argument" (keys known at plan time): Terraform language documentation, *The for_each Meta-Argument*.
- `moved` blocks for refactoring (Terraform 1.1+) and `import` blocks (1.5+): Terraform documentation, *Refactoring* and *Import*.
- `terraform test`, `expect_failures`, and plan-time evaluation limits: Terraform documentation, *Tests*.
- `optional()` object attributes with defaults (1.3+): Terraform documentation, *Type Constraints*.
- S3-native state locking with `use_lockfile` (1.10+) and deprecation of `dynamodb_table` (1.11): [S3 native state locking](https://www.bschaatsbergen.com/s3-native-state-locking), [explainer](https://dev.to/aws-builders/terraform-state-locking-without-dynamodb-s3-native-locking-explained-448l).
- `mock_provider`, `mock_resource`, `mock_data` and `override_resource` (1.7+): Terraform documentation, *Tests — Mocking and overrides*. The three behaviours that cost time (random values failing provider format validation, type-wide defaults, no force-replacement modelling) were established by running them — see T17–T19.

**AWS**
- ECS Fargate task definition and service arguments, deployment circuit breaker, `enable_execute_command`: AWS provider documentation for `aws_ecs_service` / `aws_ecs_task_definition`; ECS developer guide, *Deployment circuit breaker* and *Using Amazon ECS Exec*.
- RDS-managed master credentials in Secrets Manager (`manage_master_user_password`), IAM database authentication, and static vs dynamic parameters (`apply_method = "pending-reboot"`): RDS user guide, *Password management with AWS Secrets Manager*, *IAM database authentication*, *Working with parameter groups*.
- ALB target-group replacement requiring `create_before_destroy` with `name_prefix`, and the six-character `name_prefix` cap: AWS provider documentation for `aws_lb_target_group`; ELB API `CreateTargetGroup` limits.
- `aws_vpc_security_group_ingress_rule` as the per-rule replacement for inline `ingress` blocks: AWS provider documentation, and the provider 5.x migration notes.
- GitHub Actions OIDC federation, and the `sub` claim conditions that scope a role to a repository and ref: GitHub documentation, *Configuring OpenID Connect in Amazon Web Services*; AWS IAM guide, *Creating a role for web identity*.
- Session Manager, the `community.aws.aws_ssm` connection plugin's S3 transfer bucket, and **hybrid activations** for non-EC2 machines: AWS Systems Manager user guide, *Session Manager* and *Managed instances in a hybrid and multicloud environment*; `community.aws.aws_ssm` connection plugin documentation.
- `amazon.aws.aws_ec2` inventory plugin: `keyed_groups`, `compose`, `hostnames`, caching and `strict`: amazon.aws collection documentation.
- EC2 Image Builder as the place kernel boot arguments belong for an autoscaled fleet: Image Builder user guide, *Build and test components*.

**Kernel tuning**
- Kernel command-line parameters and their absence of a runtime equivalent: `kernel-parameters.txt` in the Linux source tree.
- RHEL 9 BLS entries, `grubby --update-kernel=ALL`, and updating `/etc/default/grub` so a newly installed kernel inherits the arguments: Red Hat documentation, *Configuring kernel command-line parameters* and *Managing boot entries*.
- Debian/Ubuntu `/etc/default/grub.d/*.cfg` sourcing order: **verified by reading `/usr/sbin/grub-mkconfig` on `ubuntu:24.04`** (lines 160–169: `/etc/default/grub` first, then the drop-in directory in glob order, both sourced as shell — so the last assignment wins). Ubuntu cloud images ship `50-cloudimg-settings.cfg`, which is what makes the ordering matter.
- SUSE bootloader configuration and `grub2-mkconfig`; `transactional-update grub.cfg` on read-only-root systems: SUSE documentation, *The boot loader GRUB 2*.
- Transparent huge pages and database latency: MongoDB, Redis and Oracle documentation all specify `transparent_hugepage=never`; the runtime interface is `/sys/kernel/mm/transparent_hugepage/enabled`, which resets on boot.
- `net.ipv4.tcp_tw_recycle` removed in Linux 4.12 (commit `4396e46187c`), and why `tcp_tw_reuse` is the one that is still safe: kernel `ip-sysctl.txt`.
- `nf_conntrack` `hashsize` as a module load parameter rather than a sysctl: kernel `nf_conntrack-sysctl.txt` and the module's own parameters.
- BBR requiring `fq`/`fq_codel` pacing: kernel `tcp.txt`; the BBR paper's pacing requirement.
- Kubernetes node sysctls that break at scale (`fs.inotify.*`, `kernel.pid_max`, ARP `gc_thresh*`, `vm.max_map_count`): Kubernetes documentation, *Using sysctls in a cluster*, and the kubelet's own eviction documentation for cgroup v2 and PSI.
- `pam_limits` applying to login sessions and **not** to systemd services (`DefaultLimitNOFILE` in `system.conf` instead): `limits.conf(5)` and `systemd-system.conf(5)`.

**cloud-init**
- `#cloud-config` as the format marker, `preserve_hostname`, and `cloud-init schema` as a validator: cloud-init documentation, *User data formats* and *CLI — schema*.

**Ansible**
- Role argument validation (`meta/argument_specs.yml`): Ansible documentation, *Roles — role argument validation*.
- Rolling updates, `serial`, `max_fail_percentage`: Ansible documentation, *Controlling playbook execution*; [rolling updates and failure controls](https://oneuptime.com/blog/post/2026-07-24-ansible-rolling-updates/view), [max_fail_percentage](https://oneuptime.com/blog/post/2026-02-21-ansible-max-fail-percentage-failure-thresholds/view).
- Windows over WinRM: transports, CredSSP delegation risk, Kerberos under FIPS, the double hop: [Ansible WinRM documentation](https://docs.ansible.com/projects/ansible/latest/os_guide/windows_winrm.html).
- sshd reads configuration in order and uses the first value obtained for most keywords: `sshd_config(5)`.

**Bare metal**
- Kickstart syntax, and the absence of line continuation: `pykickstart` / RHEL 9 installation documentation; confirmed with `ksvalidator -v RHEL9`.
- iPXE chainloading, the `user-class "iPXE"` loop-breaker, and declaring RFC 4578 option 93 in ISC dhcpd: iPXE documentation, *Chainloading iPXE*; confirmed with `dhcpd -t`.
- Bare-metal provisioning tooling (Ironic, Foreman, MAAS, Tinkerbell, Redfish): [bare metal automation overview](https://www.atlantic.net/dedicated-server-hosting/bare-metal-automation-provisioning-tools-lifecycle-management/), [provisioning explainer](https://netactuate.com/blog/bare-metal-provisioning).

**Platforms**
- Spacelift concepts (stacks, spaces, Rego policies, drift detection, worker pools): [spacelift.io](https://spacelift.io/terraform-automation), [multicloud governance](https://spacelift.io/blog/spacelift-multicloud).
- Alibaba Cloud service mapping and the `alicloud` provider: [Terraform overview (ACK)](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/developer-reference/terraform-overview), [OSS Terraform](https://www.alibabacloud.com/help/en/oss/developer-reference/terraform-overview/).

## 3. Verification log

Reproduce everything automated with `make all`. Results as run:

| Check | Command | Result |
|---|---|---|
| Terraform static | `make lab1-static` | fmt clean; 8 roots `validate` OK; `tflint` rc=0 on all 8 |
| Terraform scan | `make lab1-scan` | trivy: 0 misconfigurations (local-only resources; the gate exists for real providers) |
| Module tests | `make lab1-test` | 16 passed, 0 failed (12 plan + 4 apply), ~2 s |
| AWS static | `make lab1-aws-static` | 4 roots `validate` OK; `tflint` with ruleset-aws 0.44.0 rc=0 on all 4 |
| AWS module tests | `make lab1-aws-test` | 22 passed, 0 failed (18 plan + 4 apply) against `mock_provider`, 2.7 s, no credentials |
| AWS mutation | 11 mutations: shared value in every task definition, all rules to one target group, shared task role, credential into `environment`, HTTP listener, prod replica precondition removed, read-only root off, hard-coded alarm dimension, one shared log group, rules keyed per service only, database on a different key | each turns at least one run red; table in `aws/modules/app_stack/tests/README.md`. Mutation 1 is caught at run 3 (`remove_web`), not run 2 — an image change does not alter the *set* of service names |
| AWS scan | `make lab1-scan` | trivy 0 misconfigurations across local and AWS, with 4 waivers reasoned inline (AVD-AWS-0053, 0104, 0177, 0089) |
| Guard-rail mutation | remove prod replica precondition / `:latest` validation in a scratch copy | the matching test fails in each case |
| Integration mutation | 7 mutations: shared deploy-id keepers, wrong listener target, HTTP listeners, hard-coded image, deletion protection off, `web` not removed, `create_before_destroy` restored | each turns at least one apply run red (table in `modules/app_stack/tests/README.md`) |
| Live environments | `make lab1-e2e` | dev 9 + prod 15 applied; `verify-env.py` 6/6 on both; tamper → 3 checks fail; `apply` → 2 still fail; delete + `-replace` → 6/6; destroy 9 + 15; `--destroyed` 2/2 on both; ~7 s |
| Verifier mutation | 6 out-of-band changes to live prod: delete a listener, scale api to 1, unmanaged file, rewire a listener to worker over HTTP, chmod 666, deletion protection off + tag removed | every one fails the named checks (`exists`/`wiring`/`outputs`; `integrity`/`policy`; `unmanaged`; `integrity`/`wiring`/`policy`; `integrity`; `integrity`/`policy`) |
| `for_each` examples | `make tf-examples` | 01: count 2 replace + 1 destroy vs for_each 1 destroy · 02: unknown-key error reproduced; budget change updates 1 key · 03: add CIDR → stable 2 creates, positional 4 replaces · 04: without `moved` 3 destroy + 3 create; with `moved` 3 moves, same object id |
| Env roots | `terraform plan` / `apply` / `destroy` | dev 9 resources, prod 15 |
| `for_each` isolation | plan removing `web` / bumping `api` image | only `web`'s 4 resources / only `api`'s 3 resources |
| Terraform drift | tamper → `drift-check.sh` → apply → `drift-check.sh` | exit 2 + record → exit 0, record kept |
| Ansible lint | `make lab2-static` | production profile: 0 failures in 68 files (including the `kernel` role) |
| AWS inventory parse | `make lab2-static` | `ansible-inventory -i inventory/aws_ec2.yml` parses; returns an empty `aws_ec2` group with no credentials |
| Kernel role, four distributions | `tests/kernel-multidistro.sh` | 20 artifact assertions pass; `changed=0` on all four hosts on run 2. RHEL/Amazon get `GRUB_CMDLINE_LINUX`, SUSE `GRUB_CMDLINE_LINUX_DEFAULT`, Ubuntu a `99-` drop-in; negative assertions confirm neither family gets the other's key |
| Kernel input contract | `tests/kernel-contract.sh` | 16 of 16. 7 inputs rejected with the expected message (unknown profile, bad limits item, missing domain, **removed sysctl key**, typo'd key, boot argument with whitespace, no sysctl binary) |
| Kernel boot-argument merge | same script, against a seeded vendor `/etc/default/grub` | `crashkernel`, `resume`, `rd.lvm.lv`, `console` preserved; stale `hugepages=99` and `transparent_hugepage=always` removed; no key twice; switching to a profile with no boot arguments removes them and keeps the vendor's |
| Kernel reboot, real kernels | `tests/kernel-reboot.sh` on four QEMU VMs | four phases: apply (PENDING), reboot (ACTIVE, verified independently of Ansible against `/proc/cmdline` and `/sys`), re-apply (`changed=0`), kernel upgrade + re-apply. Tables below |
| Kernel role on EC2 | `labs/lab2-ansible/aws/` | `terraform validate`, `tflint` with the aws ruleset, `trivy` - all clean. The inventory template in `outputs.tf` was rendered offline with placeholder instance data and parsed as YAML, confirming it produces the group `kernel.yml` targets with the right per-host variables. **Not applied**: it creates billable instances |
| Kernel verification reporting | `make lab2-kernel-demo` | boot arguments pending 4 (rhel/database), 1 (ubuntu/throughput), 9 (suse/low-latency), 3 (amazon/container-host); THP state read from `/sys`, sysctl values compared against `/proc/sys` |
| Converge | `ansible-playbook site.yml` | 6 hosts, `sshd effective config matches baseline` on all |
| Idempotence | `tests/idempotence.sh` | 6 hosts, `changed=0` on run 2 |
| Anti-patterns | idempotence test on `not-idempotent.yml` / `idempotent.yml` | 6 of 6 tasks changed / 0 changed |
| Lint vs. anti-patterns | ansible-lint (production) on `not-idempotent.yml` | 5 of 6 tasks flagged; the timestamp task not flagged |
| Input contract | `tests/input-validation.sh` | 8 of 8 rejected with the expected message |
| Effective-config check | `99-` drop-in on `web02` without `10-` | tasks succeed, `sshd -T` shows `permitrootlogin yes`, verify fails the host |
| Rolling patch | `patch.yml`, then `--limit @reports/patch.retry` | stops after web01, web02, web03; db/app untouched; retry run: 3 of 3 patched |
| Ansible drift | tamper db01 → `drift-check.sh` → converge → `drift-check.sh` | exit 2 (1 host, 2 tasks) + record → exit 0, record kept |
| Bare-metal unit tests | `make lab3-test` | 39 passed (20 physical, 19 cloud) |
| Cloud record validation | `./scripts/validate_hosts.py` | 3 physical + 3 cloud valid; 11 kinds of bad cloud record rejected, including three fleet-level rules |
| Tag contract | `test_tag_contract_produces_the_groups_the_playbooks_target` | rendered tags produce `tag_Environment_prod`, `tag_Role_database`, `tag_Service_api` and ≥ 2 `az_*` groups — the offline check on the Terraform-to-Ansible join |
| Fallback-reader mutation | remove int parsing in the stdlib YAML reader | test fails |
| Line-continuation mutation | wrap the kickstart `network` line | test fails |
| Real parsers | `make lab3-artifacts` | `dhcpd -t` pass (and fails without the generated include); `ksvalidator -v RHEL9` pass on 3 files; `cloud-init schema` pass on 3 files |
| cloud-init gate mutation | unknown key (`package_updates`), then a missing `#cloud-config` first line | each rejected with `Invalid schema: user-data`, rc=1 — so the gate is not passing vacuously |
| Acceptance play | `ansible-lint`, `--syntax-check` against generated inventory | pass / pass |

### The reboot proof

Four real VMs, each with its own kernel and bootloader. Before the reboot every managed argument is reported `PENDING`; after it, read back from `/proc/cmdline` outside Ansible:

| VM | Mechanism | Active after the reboot | Independent evidence |
|---|---|---|---|
| AlmaLinux 9.4 | `grubby` + BLS entries | `transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=1` | `/sys/.../transparent_hugepage/enabled` moved from `[always]` to `always madvise [never]` |
| Ubuntu 24.04 | `99-` drop-in in `/etc/default/grub.d` | `transparent_hugepage=madvise` | THP `always [madvise] never` - the drop-in beat the cloud image's `50-cloudimg-settings.cfg` |
| openSUSE Leap 15.6 | `/etc/default/grub` + `grub2-mkconfig` | all 8 low-latency arguments, `isolcpus=managed_irq,domain,1 nohz_full=1 rcu_nocbs=1` | THP `[never]`; on this family writing the file alone would have changed nothing |
| Amazon Linux 2023 | `grubby` + BLS, inherited from the RHEL family | `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all psi=1` | booted 6.1.186 on the current AL2023 image |

And the kernel upgrade, phase 4, on the two hosts where one was available:

| VM | Kernel before | Kernel after | Did the tuning come with it? |
|---|---|---|---|
| AlmaLinux 9.4 | 5.14.0-427.13.1.el9_4 | **5.14.0-687.48.1.el9_8** (a real 9.4 to 9.8 jump) | inherited all four arguments - which is what the second write to `/etc/default/grub` is for |
| Ubuntu 24.04 | 6.8.0-31-generic | **6.8.0-139-generic** | its drop-in is read by `grub-mkconfig` for every entry, so nothing to inherit or lose |
| openSUSE Leap 15.6 | 6.4.0-150600.23.100 | no upgrade available | - |
| Amazon Linux 2023 | 6.1.186-228.374 | already newest | - |

Then the role was re-applied with `kernel_fail_on_reboot_required: true`, which makes "still pending" a hard failure, and every host came back with every argument active on the new kernel. That is the answer to "what happens at the next kernel update": **re-run the role**, and a scheduled converge does it for you.

Also confirmed after each reboot: `vm.swappiness` reloaded from `/etc/sysctl.d/90-canon-kernel.conf` by `systemd-sysctl`. Layer 1 persists by a different mechanism from layer 3, so it is worth asserting separately rather than assuming one implies the other.

**A finding the reboot produced on its own:** `hugepages=1` was active in `/proc/cmdline` and
`/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages` was **0**. A hugepage count is a REQUEST - the kernel reserves what it can find contiguously at boot and carries on with less, saying so once in dmesg. Every check that stops at "is the argument active?" reports success while the workload gets small pages. The verifier now compares the request with the reservation and fails on a shortfall, and the VM that asked for a 1GB page was given the memory to hold one.

## 4. Bugs found while building this, and how

### Terraform

| # | Bug | Found by | Fix |
|---|---|---|---|
| T1 | One `random_id` shared by every service (keepers = the service set): removing `web` **replaced `api`** | planning a key removal and reading the JSON plan | per-service `random_id.deploy[each.key]`; regression test `deploy_ids_are_keyed_per_service` |
| T2 | A test asserted on rendered `content`, which embeds an apply-time value: *"Condition expression could not be evaluated at this time"* | `terraform test` | assert on the typed variable, which is known at plan |
| T3 | A mutation of `condition = true` rejected by Terraform: *"must refer to at least one object"* | the mutation check itself | mutate to an always-true expression that references `each.value` |
| T4 | `drift-check.sh` `cd`'d into the root and then deleted the saved plan, so it was invisible and gone | a user looking for the file | explicit archive + `KEEP_PLAN=1` |
| T5 | Drift `index.csv` invalid: `for_each` addresses contain `"` | parsing with `csv.DictReader` | RFC 4180 quote doubling |
| T6 | Two drift runs in the same UTC second would target one read-only record directory, losing the second | reasoning about read-only records; tested by pre-creating directories | `-2`, `-3` suffixes |
| T7 | Drift viewer printed two identically truncated JSON blobs for a changed attribute | viewing a real `replace` | flatten JSON-valued attributes: `content.image: web:2.1.0 -> web:2.2.0` |
| T8 | A `sed` meant to change an image tag matched nothing, so a test "passed" while testing nothing | re-reading the output | re-run against the real value; lesson applied in `tamper.sh` |
| T9 | Example 04's cleanup left `.work/` behind: the trap used a relative path after `cd` | `ls` after the demo | absolute path |
| T10 | `terraform import` isn't supported by `local_file` | trying it | `import` block shown as reference; `-replace` demonstrated live |
| T11 | `create_before_destroy = true` on the fixed-name datastore: `apply -replace` created the new file, then destroyed the old one **at the same path**. `Apply complete! 1 added, 1 destroyed`, resource in state, nothing on disk | `verify-env.py` `exists` check after a remediation | lifecycle block removed; integration run `replace_datastore` (mutation-checked) |
| T12 | Prod was only ever *planned* in the README walkthrough, so cleanup reported `0 destroyed` for prod and nothing had tested a live environment | a user running cleanup | Exercise A applies both roots; Exercise B verifies them; `make lab1-e2e` runs the lifecycle |
| T13 | Permission drift is invisible to Terraform: `local_file` doesn't refresh file mode, so `plan` said *No changes* on a 0666 datastore and `apply` didn't fix it | `verify-env.py` still failing after a successful apply | documented as a plan blind spot; `integrity` check compares mode; remediated with `-replace` |
| T14 | With the datastore missing, the verifier derived the environment from it and reported every object as mis-tagged | reading the failure output | environment taken from the first readable object |
| T15 | `for_each` over `toset([443, 8443])` rejected: *"for_each supports maps and sets of strings, but you have provided a set containing type number"* — for_each keys are always strings | first `terraform test` run of the AWS module | a map keyed by `tostring(port)`, so `each.value` stays a number and nothing downstream converts it back |
| T16 | The fix for T15 then failed with *"Two different items produced the key 443"*: two public services on the same port | the next run | `distinct()` BEFORE the map is built. Deduplicating inside a `for` expression is not possible — only `...` grouping is, which gives a list per port |
| T17 | A mocked apply failed on every ARN-typed attribute: `"load_balancer_arn" (g37mq6n0) is an invalid ARN: arn: invalid prefix`. A mock invents a random 8-character string, and **the provider's own schema validation still runs**. Plan-only runs never hit it, because validation skips unknown values | switching the first integration run to `command = apply` | realistic `mock_resource`/`mock_data` defaults for anything another resource parses. `aws_iam_policy_document.json` needed one too (*"contains an invalid JSON policy: not a JSON object"*) |
| T18 | The obvious fix for T17 would have **silently destroyed the tests**: a `mock_resource` default applies to every instance of that type, so defaulting `aws_lb_target_group.arn` gives `api` and `web` the same ARN and every "each rule forwards to its own target group" assertion passes proving nothing | noticing that a type-wide default and a per-key assertion cannot both be right | fixed ARNs only where the module has exactly one of something (the load balancer, the CMK); `override_resource` per address for everything per-key. `mock_resource` is per type, `override_resource` is per address |
| T19 | `output.task_definition_arns["api"] != run.create...` failed even though the image had changed: **a mock does not model force-replacement**, so it returns the ARN it generated once. "Was this replaced?" is not a question a mock can answer, and an assertion phrased that way passes for the wrong reason | the coupling test failing on a correct module | the module publishes `task_definition_digests` — a digest of the rendered definition, computed by Terraform not the provider — which is honest under mocks, identical against a real account, and useful on its own for "did this commit change the api service?" |
| T20 | An assertion was simply wrong: `add_a_port` claimed adding a port must **not** change the task definition. The module was right — the container has to listen on the port, so it appears in `portMappings` | the test failing on correct code | assertion inverted, and the comment records the reversal. Worth knowing before a change window: *"just add a port to the ALB" is a redeploy of the service* |
| T21 | Plan-time assertions on `kms_key_id != null` and log-group ARNs failed with *"Condition expression could not be evaluated at this time"* — same family as T2, but from a *reference to another resource's* computed attribute rather than a rendered value | `terraform test` | plan runs assert only what is knowable from configuration; "everything is on the same CMK" moved to the apply run, where it is a stronger claim anyway |

### Ansible

| # | Bug | Found by | Fix |
|---|---|---|---|
| A1 | AlmaLinux 9 image ships `sshd_config.d/25-permitrootlogin.conf` (`PermitRootLogin yes`); a later-sorting hardening drop-in is silently overridden | probing `sshd -T` before writing the role | drop-in named `10-baseline.conf`; `verify.yml` asserts on `sshd -T` |
| A2 | `argument_specs` accepts a YAML boolean for a `str` option whose choices include `"no"`/`"yes"`; it reached the template as `False` | `tests/input-validation.sh` case failing with an unexpected message | explicit `is string` assertion in `validate.yml` |
| A3 | Minimal image has no `/etc/sysctl.d` and no `sysctl` binary | first converge failed | `file: state=directory`; `procps-ng` in baseline packages |
| A4 | Verification in check mode would fail on every drifted host, turning DRIFT into INCOMPLETE | reasoning through `drift-check.sh` exit codes | verify skipped when `ansible_check_mode` |
| A5 | `ansible-playbook --check` exits 0 when it finds drift | running it | wrapper derives exit 2 from per-host `changed` |
| A6 | JSON callback output corrupted by `profile_tasks` lines; `ANSIBLE_CALLBACKS_ENABLED=` (empty) crashes ansible-core 2.21 | parsing failures | set it to `ansible.posix.json` |
| A7 | An unreachable host produced **no drift record**: the retry-file hint is printed to stdout above the JSON | a nonexistent `ghost01` host | `ANSIBLE_RETRY_FILES_ENABLED=false` for read-only runs |
| A8 | Template diffs recorded the controller's temp path (including a local home directory) as the "after" header | reading a drift record | viewer shows destination file + template name |
| A9 | On a fresh clone `reports/run/` doesn't exist; the canary's first record write failed | running `patch.yml` after deleting `reports/` | play creates the directory first |
| A10 | A `rescue`d failure is not counted toward `max_fail_percentage`; the run continued into the next batch | a control play with a plain failing command | fail the host again outside the block |
| A11 | Retry file lists the whole aborted batch, including the host that passed | reading `patch.retry` | documented; harmless because the role is idempotent |
| A12 | `community.docker` 3.3.2 in the user collection path shadowed 5.3.0 and broke on ansible-core 2.21 | connection errors | project-local `collections_path` + pinned `requirements.yml` |
| A13 | Containers have no usable `HOME` for remote tmp | module failures | `remote_tmp = /tmp/.ansible` |
| A14 | `lookup('file', ...)` reads the **controller**, not the target | wrong content | `command: cat` on the target |
| A15 | Tampering before the baseline existed: `/etc/ssh` absent on fresh hosts | a user running the drift demo | `tamper.sh` refuses without a baseline and verifies the edit landed |
| A16 | A first verification of the override case passed vacuously because the correct `10-` file was still present | noticing the result was too good | removed `10-` first; the check then failed as intended |
| A17 | The kernel role's shell tasks failed on Ubuntu only: `/bin/sh: 1: set: Illegal option -o pipefail`. `/bin/sh` is dash on Debian and Ubuntu, and dash has no `pipefail` | the four-distribution run: RHEL passed, Ubuntu failed on the same task | `executable: /bin/bash` on the role's shell tasks — the *less* portable-looking choice is the portable one here, since all four distributions ship bash and ansible-lint's `risky-shell-pipe` requires pipefail. The one file that must stay POSIX sh is the grub drop-in, because `grub-mkconfig` sources it with `/bin/sh` |
| A18 | Every module failed on SLES with `SyntaxError: future feature annotations is not defined`. The BCI base image's `python3` is **3.6.15**, and ansible-core's modules need ≥ 3.7 | the SUSE host failing at Gathering Facts | install `python311` and pin `ansible_python_interpreter`. An ancient system Python that cannot be removed, beside a modern one, is the normal state of a long-lived enterprise distribution — the interpreter has to be chosen, not discovered |
| A19 | `--tags kernel_bootloader` failed with *"'kernel_grub_file' is undefined"*: the tag filter skipped the tasks that load the per-distribution mechanism | running exactly that command to test one section | `tags: [always]` on the four platform/profile-loading tasks. They are prerequisites of every other tag, not a section of their own |
| A20 | Every `--check` run failed with *"object of type 'dict' has no attribute 'rc'"*. The `raw` interpreter probe is skipped in check mode, so the following `when: kernel_python.rc != 0` had nothing to read — which broke the whole input-contract suite for the wrong reason | the first run of `tests/kernel-contract.sh`: 7 of 7 cases "failed" with rc=2 | `check_mode: false` on the probe; it is read-only |
| A21 | `validate:` on the sysctl file would have been actively harmful: `sysctl -p <file>` **parses and applies** in one step and has no dry-run flag, so it would apply values from a temporary file before Ansible decided to keep it — and fail outright where `/proc/sys` is not writable | writing the task by analogy with the `sshd -t` and `visudo -c` validations | no `validate:`; the safety net is the `/proc/sys` key-existence check before anything is written. Knowing which of your config files can be checked by their own parser, and what to do about the ones that cannot, is the difference between a habit and a practice |
| A22 | ansible-lint's production profile raised 73 × `var-naming[no-role-prefix]`: role variables must be prefixed with the **role name**, and the role was `kernel_tuning` with `kernel_*` variables | `ansible-lint` after the role was working | renamed the role to `kernel`. The alternative was `kernel_tuning_sysctl_extra` everywhere; the rule is right and the shorter name is better |
| A23 | `schema[meta]`: Galaxy's platform list does not know Amazon Linux 2023 — it accepts only 6.1, 7.1, 7.2 or `all` | the same lint run | `versions: [all]`, with a comment saying the role is actually tested on 2023 |
| A24 | A test case was wrong, not the code: it asserted that requesting a runtime sysctl load on Ubuntu would be refused for lack of `procps`. `ubuntu:24.04` **does** ship `sysctl` | the case failing with rc=0 | the missing binary is simulated by pointing `kernel_sysctl_binary` at a path that is not there, which is the real state of a minimal image before the baseline role runs. The comment records the wrong assumption |
| A26 | Every play against the new VM inventory failed with *"Failed to create temporary directory"*, and `-vvv` showed `ESTABLISH DOCKER CONNECTION FOR USER: root` - the VM inventory's own `ansible_connection: ssh` was being ignored | reading the verbose output instead of the error message | Ansible's variable precedence: **inventory-FILE group vars (3) rank BELOW inventory `group_vars/all` (4)**, so `all.yml`'s container connection - correct for the container labs, and loaded for every inventory in this project - silently won. Moved to `group_vars/kernel_vms.yml` (precedence 6). Anything that must override a fleet-wide default belongs in `group_vars/<group>.yml`, never inline in an inventory file |
| A27 | The strict sysctl check failed on the throughput host with *"net.netfilter.nf_conntrack_max is not present in this kernel"* - on a real kernel that has it, once `nf_conntrack` is loaded | the first real-VM converge. The container run never hit it, because `kernel_sysctl_strict` is off there | The check lived in `validate.yml`, which runs BEFORE `modules.yml`. The ordering comment in `tasks/main.yml` says modules must precede sysctls *because a key provided by a module does not exist until the module is loaded* - and the check enforcing exactly that was itself running too early. Moved into `sysctl.yml` |
| A28 | After a successful reboot the play's summary still reported `boot_args_pending=4`, about a host that had just come back with all four active | reading the output of the run that had just proved the opposite | `kernel_report` was collected once, before the reboot, and never refreshed. The collection moved into `verify-collect.yml` and now runs TWICE - before, and again after - so every assertion and the summary describe the kernel that is running now |
| A29 | Amazon Linux 2023's arm64 image booted its kernel and then stalled forever with nothing on the console. **Two independent causes.** QEMU's `virt` machine still defaults to GICv2 and AL2023's arm64 kernel needs GICv3; and - the real one - the qcow2 overlay was created with a hard-coded 20G while that image's virtual size is **25G**. `qemu-img` accepts an overlay smaller than its backing file without complaint, and the guest then sees a truncated disk: grub and the kernel sit near the start and load fine, the root partition is past the end and cannot be mounted | comparing `qemu-img info` virtual sizes across all four images, after the GIC fix alone did not help | `-machine virt,gic-version=max`, and the overlay created with **no size at all** so it inherits the backing file's, then grown. The first attempt at that fix parsed the size out of `qemu-img info` with a greedy `sed`, silently matched the wrong field, and reproduced the bug with more code |
| A33 | The reboot test's "every managed boot argument is live" check **silently skipped itself on Ubuntu**, reporting *"this profile owns no boot arguments"* about a host that owns one. The Debian family keeps its keys in its own drop-in rather than in an ownership marker, and the fallback that read them had a quoting bug, so the variable came back empty - and an empty list of expectations is a check that passes without checking | reading the passing output carefully rather than the summary line. The THP assertion next to it still passed, which is what made it easy to miss | extraction rewritten with `grep | cut -d'"' -f2`. A check that can quietly decide it has nothing to do is worse than one that fails |
| A34 | The test was documented as taking `--inventory` so the same four phases could run against the EC2 rig, and **it did not**: hosts, ports and the kernel-upgrade command were all hard-coded to the four local VM names. The AWS README described a command that would have matched zero hosts and exited 0 | writing the AWS README before the test supported it, then testing the patch on a COPY of the script first, which also caught that `ansible-inventory --list` does **not** render Jinja in host vars - the ssh key path arrives verbatim as `{{ lookup(...) }}` | hosts now come from `ansible-inventory`, the upgrade command is chosen by probing for the package manager rather than matching the host's name, and a templated key path falls back to the same default the inventory uses |
| A32 | The first play against freshly-built VMs failed on the SUSE host with *"The module interpreter '/usr/bin/python3.11' was not found"* - on a host whose cloud-init installs exactly that. **Two layers of wrongness.** First, sshd answering is not "the machine is ready": cloud-init starts sshd and runs `runcmd` in its FINAL stage, so there is a window in which you can log in and the interpreter is still installing. Second, and worse, when the `zypper` install failed cloud-init carried on to the next command and **wrote the readiness sentinel anyway** - a readiness signal that fires whether the work succeeded or not is worse than no signal at all | rebuilding the VMs from scratch for a clean run, having only ever tested against VMs that had been up for a while | the interpreter install moved OUT of cloud-init and into `vms/up.sh`, over ssh, with a retry and an explicit `test -x` afterwards - exactly how `setup-distros.sh` already did it for the containers. Readiness now means the thing that actually matters |
| A30 | **The role was not idempotent on the whole RHEL family**: every run reported `changed` on the grubby task, because it was written with `changed_when: true`. That is the exact anti-pattern `examples/idempotence/` exists to demonstrate - a play that always reports changed hides the run that really changed something | phase 3 of the reboot test (`re-apply must change nothing`), which containers cannot run because they have no grubby | `changed_when` now compares the default boot entry's argument SET before and after, sorted, because grubby is free to reorder what it writes |
| A31 | **Amazon Linux 2023 was getting the arguments written to a variable it does not use, and then the role's own next task wiped them.** Two facts, both invisible in a container and neither documented together anywhere: AL2023 ships its kernel arguments in `GRUB_CMDLINE_LINUX_DEFAULT` and leaves `GRUB_CMDLINE_LINUX` empty (RHEL 9 and AlmaLinux do the exact opposite), and `grubby --update-kernel=ALL --remove-args=...` on AL2023 **blanks the whole of `GRUB_CMDLINE_LINUX`** rather than just the named keys | phase 3 again: AL2023 reported `changed` on *two* bootloader tasks every run. Measured directly - write `GRUB_CMDLINE_LINUX="probe_marker=1"`, run `grubby --remove-args`, read back `GRUB_CMDLINE_LINUX=""`; on AlmaLinux 9 the same command leaves the line untouched, and `_DEFAULT` survives on AL2023 | `vars/distro-Amazon.yml` overrides `kernel_grub_cmdline_key: GRUB_CMDLINE_LINUX_DEFAULT`, which is both the key AL2023 actually reads and the one grubby leaves alone. The reboot test had been PASSING while this was broken, because grubby had done its half correctly - the half that was being erased is the one that matters after the next `dnf update kernel` |
| A25 | **The role could add a boot argument and never remove one.** With the profile switched to one that owns no boot arguments, there were no keys to strip, so `transparent_hugepage=never` stayed on the line forever — coming back after every reboot with no line in any playbook to explain it | a contract-test case written for exactly this, which failed | the role records the keys it owns in a `# canon-kernel-managed:` marker in the file and strips **previous ∪ current** on the next run. Declarative means removals work, and removals need a record of what you previously owned. The Debian drop-in needs no marker: everything it manages lives in its own file, which is the real argument for drop-in directories over editing shared files |

### Bare metal

| # | Bug | Found by | Fix |
|---|---|---|---|
| B1 | `option architecture-type` isn't defined in ISC dhcpd; the server would refuse to start | `dhcpd -t` | declare `option client-arch code 93 = unsigned integer 16;` |
| B2 | Kickstart `network` command wrapped with `\`: parsed as unknown commands, so the bond/IP/VLAN would never be configured | `ksvalidator -v RHEL9` | one line; unit test forbids trailing backslashes |
| B3 | `%packages --minimal` isn't a valid option | `ksvalidator` | removed; `@^minimal-environment` already selects the minimal set |
| B4 | Generated DHCP reservations spanning two subnets were included inside one subnet block | reviewing ISC dhcpd scoping | include at global scope |
| B5 | `cat | grep` pipeline without `pipefail` in the acceptance play would mask a missing bond | ansible-lint `risky-shell-pipe` | `grep` reads the file directly |
| B6 | The new cross-file hostname rule **rejected the fixture added for it**: `canon-db01` existed in both `hosts.yml` and `cloud-hosts.yml` | the first run of `./scripts/validate_hosts.py` after adding the cloud half | renamed the cloud instance to `canon-pg01`. The rule earned its keep before it was committed, which is the best argument for fleet-level rules over record-by-record review |
| B7 | The `cloud-init schema` gate could have been vacuous | deliberately breaking a rendered file twice | an unknown key (`package_updates` for `package_update`) and a missing `#cloud-config` first line were each rejected with rc=1. The second is the dangerous one: without that line cloud-init treats the file as a shell script and ignores the whole thing, so the instance boots, passes its health check, and ran none of its configuration |

## 5. Known limits

- The $0 lab resources are local stand-ins. `labs/lab1-terraform/aws/` is the real provider, but it is **apply-tested against mocks**, and a mock is not AWS: it accepts an invalid subnet id, an ALB name already taken in the account, a Fargate cpu/memory pair the API rejects, an IAM policy that denies what the task needs, or a quota already reached. It also does not model force-replacement (T19). API errors, eventual consistency and provider-specific ForceNew behaviour are described, not exercised. The missing gate is a nightly apply/destroy into a sandbox account.
- **Neither AWS environment root is applied by any target.** Applying costs money and touches a real account, so it stays a deliberate act; the cost table in `aws/README.md` says what it would be, and the NAT gateway is usually the surprise.
- The `aws_ec2` dynamic inventory and the Session Manager connection are **reviewed, not run**: both need credentials. `make lab2-static` proves the plugin is installed and the configuration parses. Worth knowing: without credentials the plugin returns an **empty group rather than an error**, so "no hosts matched" is what a missing identity looks like.
- Lab hosts are containers without systemd or their own kernel, so service reloads and `sysctl -p` are skipped by design, and the kernel role's `kernel_sysctl_strict` check is disabled for them (inside a container `/proc/sys` is the *host's* key set, not the distribution's). Those paths run on VMs and physical hosts, and `tests/kernel-contract.sh` exercises the strict check by turning it on with a key no kernel has any more.
- The kernel role's **boot-argument layer is verified by its artifacts, not by a reboot.** A container has no bootloader, so the generator step reports that it could not run and the arguments are staged — correct in an image build, and a gap here: the role's post-reboot confirmation path (`kernel_reboot_ok: true`) is written and syntax-checked, not executed.
- `bmc_baseline.sh`, `ssm_hybrid_register.sh` and `acceptance.yml` target hardware and an AWS account that don't exist here; they are syntax-checked and linted, not executed. The hybrid-activation script's source-of-truth guard *is* exercised.
- The tag contract between the three labs is asserted on the **rendered** tags and the **module's** tags independently. Nothing compares the two sets automatically, so adding a tag to lab 1's module and not to lab 3's renderer would pass both suites.
- Every result in this file was produced on a laptop (Darwin, aarch64). The CI workflow's `static-and-unit`, `ansible` and `bare-metal` jobs have since run green on GitHub-hosted runners; the `kernel` job was added with this work and has **not** yet run there, so its image pulls (three registries, including `registry.suse.com`) and the `python311` install on SLES are unverified on an x86_64 runner.
