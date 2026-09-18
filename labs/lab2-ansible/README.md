# Lab 2 — Ansible: a reusable, idempotent role, safe rollouts, and drift detection

Six throwaway containers stand in for six servers. No VMs, no SSH keys, no cost. The containers don't matter here: **the role design, the rollout structure and the tests are the substance**, and they are identical on VMs or physical hardware. Only the connection settings in `inventory/group_vars/all.yml` would change.

## What this lab demonstrates

| Capability | Where | Verified by |
|---|---|---|
| A **reusable role** with a validated input contract | `roles/baseline/` | `tests/input-validation.sh` — 8 bad inputs rejected |
| **Idempotence**, proven rather than claimed | `roles/baseline/` | `tests/idempotence.sh` — 6 hosts, 0 changes on run 2 |
| What non-idempotent code looks like, side by side with the fix | `examples/idempotence/` | same test: 6 of 6 tasks caught, then 0 |
| Verifying **effective** config, not just files | `roles/baseline/tasks/verify.yml` | catches a vendor sshd drop-in overriding ours |
| One role, many host types, via inventory layering | `inventory/group_vars/` | web, db and app get different tuning from one role |
| A **safe rolling patch**: canary, batches, abort, quarantine, retry | `patch.yml`, `roles/patch/` | run stops after 3 hosts; retry touches only failures |
| **Drift detection** with an exit code and a record that survives the fix | `drift-check.sh`, `drift-show.py` | exit 2 on drift, 0 after remediation, record kept |
| **Kernel tuning that survives a reboot** on RHEL, Ubuntu, SUSE and Amazon Linux | `roles/kernel/` | `tests/kernel-multidistro.sh` — 4 distributions, 4 mechanisms, 20 artifact assertions, 0 changes on run 2 |
| Declarative **removal** of a boot argument, not just addition | `roles/kernel/tasks/bootloader-file.yml` | `tests/kernel-contract.sh` — vendor arguments preserved, stale values gone, no key twice |
| The same fleet on **AWS**: inventory from tags, access without SSH | `inventory/aws_ec2.yml`, `inventory/group_vars/aws_ec2.yml` | `make lab2-static` parses the plugin config; groups match lab 3's rendered tag contract |
| Lint-clean at the strictest profile | `.ansible-lint` | `ansible-lint` — `production` profile passes |

## Layout

```text
lab2-ansible/
├── ansible.cfg              # project-local config: inventory, collections path, forks, retry files
├── requirements.yml         # pinned collections (installed into ./collections by setup.sh)
├── site.yml                 # converge every host to the baseline role
├── patch.yml                # rolling patch: serial, max_fail_percentage, health gate, quarantine
├── kernel.yml               # kernel tuning across four distributions, serial, with a reboot gate
├── inventory/               # hosts on three axes + group_vars layering
│   ├── hosts.yml            # the six lab containers
│   ├── kernel-hosts.yml     # the four distribution containers
│   ├── aws_ec2.yml          # PRODUCTION inventory: EC2, grouped by the tags Terraform stamps
│   └── group_vars/aws_ec2.yml  # Session Manager instead of SSH; secrets from Secrets Manager
├── roles/
│   ├── baseline/            # the reusable, idempotent, validated role
│   ├── kernel/              # reboot-persistent kernel tuning, four persistence mechanisms
│   └── patch/               # one host's patch cycle; fleet logic stays in patch.yml
├── examples/idempotence/    # six anti-patterns and their fixes
├── tests/                   # idempotence, input-contract, and the kernel role's two suites
├── setup.sh / teardown.sh   # create / remove the six lab hosts
├── setup-distros.sh         # create / remove the four distribution hosts (--down)
├── tamper.sh                # simulate an out-of-band edit, and prove it landed
├── drift-check.sh           # check mode -> exit code + immutable drift record
├── drift-show.py            # read the drift archive
└── summarize.sh             # build the patch report from per-host records
```

## Prerequisites

`ansible-core` ≥ 2.15 (verified on 2.21.4), Docker, Python 3. `setup.sh` installs the pinned collections. From the repository root, `make lab2-up` then `make lab2-test` runs everything below.

---

**Every step runs from `labs/lab2-ansible/`.**

## Step 1 — create the hosts

```bash
./setup.sh
```

```bash
ansible linux -m ping
```

## Step 2 — converge with the reusable role

```bash
ansible-playbook site.yml
```

`site.yml` is five lines: `hosts: linux` and `roles: [baseline]`. Everything else is data. On the first run the role installs packages, creates the `ops` group and `alice`/`bob` (removing `carol`), writes a validated sudoers rule, hardens sshd, configures chrony and sysctl, writes the banner, and then **verifies the effective configuration**.

Look at what each tier received from the same role:

```bash
docker exec lab-web01 cat /etc/sysctl.d/90-baseline.conf; docker exec lab-db01 cat /etc/sysctl.d/90-baseline.conf
```

web gets `net.core.somaxconn`; db gets `vm.dirty_ratio`. Both keep every role default. That's the `_extra` merge pattern — see [`roles/baseline/README.md`](roles/baseline/README.md#reusability).

## Step 3 — prove idempotence

```bash
tests/idempotence.sh
```

```text
== run 2: must change nothing
   PASS  app01  changed=0
   ...
IDEMPOTENT: 6 host(s), zero changes on the second run.
```

Then watch the same test fail, and pass again, on the teaching examples:

```bash
ansible-playbook examples/idempotence/reset.yml && tests/idempotence.sh examples/idempotence/not-idempotent.yml
```

```bash
ansible-playbook examples/idempotence/reset.yml && tests/idempotence.sh examples/idempotence/idempotent.yml
```

The broken playbook reports **6 of 6 tasks changed** on a second run, and `/etc/sysctl.d/99-demo.conf` holds the same line twice. The fixed playbook reports **0**. [`examples/idempotence/README.md`](examples/idempotence/README.md) walks through each pair of tasks.

## Step 4 — prove the input contract

```bash
tests/input-validation.sh
```

Eight invalid inputs, each rejected **before any task touches a host**, with a message naming the problem. One of them is a finding worth knowing: `argument_specs` lets a bare YAML `no` (a boolean) through for an option whose choices are `"no"`/`"yes"`. The role catches it with an explicit type assertion in `tasks/validate.yml`.

## Step 5 — verify effective config, not files

The vendor image ships `/etc/ssh/sshd_config.d/25-permitrootlogin.conf` containing `PermitRootLogin yes`, and sshd uses the **first** value it reads. Name the role's drop-in so it sorts *after* that file, then watch what happens:

```bash
docker exec lab-web02 rm -f /etc/ssh/sshd_config.d/10-baseline.conf && ansible-playbook site.yml --limit web02 -e baseline_ssh_dropin=/etc/ssh/sshd_config.d/99-baseline.conf
```

```text
fatal: [web02]: FAILED! => "sshd's EFFECTIVE configuration does not match the baseline, although the drop-in was written ... Effective values: ['maxauthtries 3', 'permitrootlogin yes', 'passwordauthentication no']"
```

Every write task succeeded, and the file says `PermitRootLogin no`, but sshd would still permit root login. Only the `sshd -T` check catches this. Put web02 back:

```bash
docker exec lab-web02 rm -f /etc/ssh/sshd_config.d/99-baseline.conf && ansible-playbook site.yml --limit web02
```

## Step 6 — a safe rolling patch

```bash
ansible-playbook patch.yml
```

Batches: `web01` alone (canary), then `web02, web03`, then **the run stops**. `web03` is configured to fail its post-patch health gate, and `max_fail_percentage: 0` refuses to start the next batch. `db01`, `db02` and `app01` are never touched. **A bad change stops after three servers, not three hundred.**

```bash
./summarize.sh && cat reports/quarantine-web03.log
```

Fix the host and re-run **only the failures**:

```bash
ansible-playbook patch.yml --limit @reports/patch.retry -e simulate_health_failure=false
```

What the play's structure guarantees, and where:

| In `patch.yml` | Why |
|---|---|
| `serial: [1, 2, "100%"]` | canary, small batch, rest. A real fleet: `[1, 5, "25%"]` |
| `max_fail_percentage: 0` | abort the run instead of marching through the fleet |
| drain with `delegate_to` the LB | the pool action happens *on the load balancer*, not on the host being patched |
| role pre-flight assertions | free space on `/var`, no dnf transaction in flight, hostname matches inventory, snapshot exists |
| reboot only if `/var/run/reboot-required` | blanket reboots turn a patch window into an outage |
| health gate with `retries`/`until` | service, port, application response, not just "SSH is up" |
| `block` / `rescue` / `always` | diagnostics captured, host quarantined, and every host explicitly back in the pool or out of it |
| a `fail` task **outside** the block | a failure handled by `rescue` does **not** count toward `max_fail_percentage` — without this the run carries on into the next batch (verified on ansible-core 2.21) |
| per-host record written in `always` | the record survives an aborted run, which is when you need it most |

Observed detail: the retry file lists `web02` as well as `web03`. When the abort threshold trips, ansible-core writes the whole aborted batch to the retry file, including the host that passed. Re-running `web02` is harmless because the patch role is idempotent.

## Step 7 — drift detection with a record that outlives the fix

```bash
./tamper.sh db01 && ./drift-check.sh; echo "exit=$?"
```

```text
[DRIFT] 1 of 6 host(s) differ from baseline (all)
== db01
   TASK [baseline : SSH | Write hardening drop-in]
      -PermitRootLogin yes
      +PermitRootLogin no
[ARCHIVED] drift-history/20260917T125339Z/  (drift.txt, drift.json)
```

Remediate, then check again. The fleet is clean, and the record is still there:

```bash
ansible-playbook site.yml --limit db01 && ./drift-check.sh; ./drift-show.py
```

Design decisions:

- **Drift = what the baseline role would change.** `drift-check.sh` runs `site.yml --check --diff`, so the definition of "correct" and the definition of "drifted" come from the same code.
- **`ansible-playbook --check` exits 0 even when it finds drift.** The wrapper reads per-host `changed` counts from the JSON callback and supplies the exit code: **0** clean, **2** drift, **1** incomplete.
- **Incomplete beats drift.** An unreachable or failed host was *not checked*, and "partially checked, looked fine" is the report that hides the broken box.
- **Verification is skipped in check mode.** Nothing was converged, so asserting the effective config would fail on every drifted host and turn a DRIFT finding into an INCOMPLETE run.
- **Records are immutable and survive remediation.** Each is `drift.txt` + `drift.json`, read-only on write, with a row in `drift-history/index.csv`.

## Step 8 — kernel tuning that survives a reboot, on four distributions

```bash
./setup-distros.sh
```

Four containers: AlmaLinux 9, Ubuntu 24.04, SLES 15 and Amazon Linux 2023. Four **different** workload profiles, one role, no per-host code.

```bash
ansible-playbook -i inventory/kernel-hosts.yml kernel.yml
```

```text
ktr-rhel   (AlmaLinux 9.8, RedHat) profile=database       boot_args_pending=4 mechanism=grub-file
ktr-ubuntu (Ubuntu 24.04, Debian)  profile=throughput     boot_args_pending=1 mechanism=grub-dropin
ktr-suse   (SLES 15.6, Suse)       profile=low-latency    boot_args_pending=9 mechanism=grub-file
ktr-amazon (Amazon 2023, RedHat)   profile=container-host boot_args_pending=3 mechanism=grub-file
```

Two mechanisms, and that is the point: the RHEL family and SUSE get an in-place edit of `/etc/default/grub` (SUSE's key is `GRUB_CMDLINE_LINUX_DEFAULT`, RHEL's is `GRUB_CMDLINE_LINUX`, and only RHEL has `grubby` to update the live BLS entries); Ubuntu gets a `99-` drop-in in `/etc/default/grub.d`, because that directory is sourced **after** `/etc/default/grub` and the last assignment wins — which is how an Ubuntu cloud image's `50-cloudimg-settings.cfg` silently overrides an edit to the main file.

`boot_args_pending` is the interesting column. The bootloader is correct; the running kernel started before it. `transparent_hugepage=never` has no sysctl and no runtime equivalent, so the role **reports** what needs a reboot rather than claiming success — "the files are right" and "the kernel is running it" are different claims, which is the same distinction lab 1's `verify-env.py` draws.

```bash
tests/kernel-multidistro.sh
```

20 assertions that each distribution got **its own mechanism's artifact** — not merely that the play went green — then a second run requiring `changed=0` on all four.

```bash
tests/kernel-contract.sh
```

16 cases. Seven inputs rejected before anything is written, including the one that earns its keep: a sysctl key **this kernel does not have**. `net.ipv4.tcp_tw_recycle` was removed from Linux in 4.12 and is still in tuning guides; depending on the distribution, `sysctl --system` either skips it silently or **aborts the file**, so every key after it is never applied either.

The other nine test the key-aware merge against a realistic vendor `/etc/default/grub`:

```text
GRUB_CMDLINE_LINUX="crashkernel=1G-4G:192M resume=/dev/mapper/rhel-swap rd.lvm.lv=rhel/root console=ttyS0,115200 transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=8"
```

The distribution's own arguments survived; the stale `hugepages=99` and `transparent_hugepage=always` are gone; no key appears twice. Appending would have left both values — and the kernel takes the last one for most parameters, so it *appears* to work until it is a parameter the kernel reads first. Switching the host to a profile with no boot arguments removes them entirely, which needs the role to remember what it previously owned; it records that in a marker comment in the file.

Full reasoning, the four mechanisms, and the five profiles: [`roles/kernel/README.md`](roles/kernel/README.md).

## Step 9 — the same fleet on AWS

Nothing above changes. What changes is where the host list comes from and how the controller reaches it.

```bash
ansible-inventory -i inventory/aws_ec2.yml --graph
```

[`inventory/aws_ec2.yml`](inventory/aws_ec2.yml) asks EC2 what exists instead of reading a file, and every group it builds comes from a **tag** that lab 1's Terraform module stamps and asserts on. That is the whole handoff: Terraform creates the machine and tags it, Ansible finds it by tag, and neither keeps a list of the other's resources — so the two cannot disagree. Lab 3 renders the same tags from its source of truth and emits the groups they will produce, so the contract is [testable offline](../lab3-baremetal/README.md#the-cloud-half).

A hand-maintained host list is itself a drift surface: a server that exists and is not in the file is never patched, never checked, and never in a drift report, and nothing notices.

[`inventory/group_vars/aws_ec2.yml`](inventory/group_vars/aws_ec2.yml) connects with `community.aws.aws_ssm` rather than SSH. The instances in lab 1's module sit in private subnets with no public address and no inbound rule on port 22, so SSH would need a bastion (another host to patch and harden, holding a key that opens the fleet), a VPN a hosted runner cannot use, or a public IP on port 22. Session Manager removes the question: the agent polls **outbound**, authorisation is IAM, and CloudTrail records every session. There is no key to distribute, rotate or lose — and no Vault password either, because secrets resolve through the same identity:

```yaml
app_db_password: "{{ lookup('amazon.aws.aws_secret', 'canon/prod/db', region='us-east-1') }}"
```

Both files need credentials to return hosts, so they are reviewed rather than executed here — `make lab2-static` proves the plugin is installed and the configuration parses, which is what CI can honestly check. See [`docs/aws-platform.md`](../../docs/aws-platform.md) for what is exercised and what is not.

## Lint

```bash
ansible-lint
```

```text
Passed: 0 failure(s), 0 warning(s) in 40 files processed. Profile 'production' was required, and it passed.
```

Two rules are waived inline, with the reason next to each: `package-latest` in the patch role (upgrading *is* the point of a patch run) and `command-instead-of-shell` for the health check (real checks are pipelines).

## Teardown

```bash
./teardown.sh && ./setup-distros.sh --down
```

## Production mapping

| In this lab | In production |
|---|---|
| `community.docker.docker` connection | SSH with an automation account; key from a vault; `become` via a scoped sudoers rule |
| static `inventory/hosts.yml` | `inventory/aws_ec2.yml` on AWS, or a vCenter/CMDB plugin — both already here for the AWS half |
| `community.docker.docker` for the kernel lab | SSH or `aws_ssm`; the role's own accommodations (`kernel_sysctl_apply`, `kernel_sysctl_strict`) go back to their defaults, because a real host owns its kernel |
| kernel boot arguments staged, no reboot | applied and the reboot scheduled — or, on AWS, baked into the AMI by Image Builder with `kernel_fail_on_reboot_required: true`, because a change to a running Auto Scaling instance is lost on the next instance refresh |
| `tests/idempotence.sh` | Molecule's idempotence step, in CI on every role change |
| simulated drain | `delegate_to` the load balancer (F5, HAProxy, a cloud target group) |
| simulated dnf transaction | dnf against a **repo snapshot pinned for the whole cycle**, so host 1 and host 200 get the same packages |
| `drift-check.sh` on demand | scheduled per environment; exit 2 opens a ticket linking the record |
