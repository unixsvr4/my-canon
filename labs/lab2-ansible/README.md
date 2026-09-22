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
| ...and it really does survive one | `vms/`, `tests/kernel-reboot.sh` | 4 **real VMs** rebooted; every argument live in `/proc/cmdline`, THP actually off, hand-made `sysctl -w` drift repaired by the next converge, then a **kernel upgrade** and a re-apply |
| The same role on **real EC2** | `aws/` | 4 instances, one per family, profile driven by the `KernelProfile` tag (validated and scanned; applying costs about 0.07 USD/hour) |
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
├── kernel-rhel.yml          # ...one host at a time: imports kernel.yml, then shows that family's
├── kernel-ubuntu.yml        #    own artifact - the BLS entry, the drop-in, the generated grub.cfg,
├── kernel-suse.yml          #    both of Amazon Linux's grub keys. Four QEMU guests want about
├── kernel-amazon.yml        #    10.7GB between them, so one at a time is the laptop-sized path
├── inventory/               # hosts on three axes + group_vars layering
│   ├── hosts.yml            # the six lab containers
│   ├── kernel-hosts.yml     # the four distribution containers
│   ├── kernel-vms.yml       # the four REAL VMs (own kernel) for the reboot proof
│   ├── aws_ec2.yml          # PRODUCTION inventory: EC2, grouped by the tags Terraform stamps
│   └── group_vars/          # aws_ec2.yml (SSM, no SSH), kernel_vms.yml (connection + machine sizes)
├── roles/
│   ├── baseline/            # the reusable, idempotent, validated role
│   ├── kernel/              # reboot-persistent kernel tuning, four persistence mechanisms
│   └── patch/               # one host's patch cycle; fleet logic stays in patch.yml
├── examples/idempotence/    # six anti-patterns and their fixes
├── tests/                   # idempotence, input-contract, and the kernel role's two suites
├── setup.sh / teardown.sh   # create / remove the six lab hosts
├── setup-distros.sh         # create / remove the four distribution hosts (--down)
├── vms/                     # four REAL VMs (own kernel + bootloader) for the reboot proof
├── aws/                     # four EC2 instances, one per family (costs money; you run it)
├── tamper.sh                # simulate an out-of-band edit, and prove it landed
├── drift-check.sh           # check mode -> exit code + immutable drift record
├── drift-show.py            # read the drift archive
└── summarize.sh             # build the patch report from per-host records
```

## Prerequisites

`ansible-core` ≥ 2.15 (verified on 2.21.4), Docker, Python 3. `setup.sh` installs the pinned collections. From the repository root, `make lab2-up` then `make lab2-test` runs steps 1–7.

Steps 8–11 need more: `setup-distros.sh` pulls four distribution images (Docker); `vms/up.sh` needs **QEMU** (`brew install qemu`, verified on 11.1.1) and downloads about 3GB of cloud images into `/tmp`; step 10 needs an **AWS account** and costs about 0.07 USD an hour.

The four VMs also ask for about **10.7GB of memory** between them (4096 + 2048 + 2048 + 2560 MiB), which is most of a 16GB laptop. Every part of step 9 takes one VM name — `./vms/up.sh kvm-suse`, `kernel-suse.yml`, `tests/kernel-reboot.sh kvm-suse`, `./vms/down.sh kvm-suse` — so the whole lab runs one distribution at a time in about 2.5GB.

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

## Step 9 — reboot four real kernels, then upgrade them

Everything in step 8 is about the *files*. A container cannot test the claim those files exist to make, because it shares the host's kernel: `/proc/cmdline` inside one is the host's, and the boot arguments read `PENDING` forever.

### One distribution at a time

Booting all four at once is faster when the memory is there, because the boots overlap. It is also about 10.7GB, so the normal way to run this on a laptop is one VM at a time — and each one has a playbook of its own:

| VM | Playbook | Profile | The mechanism it ends by printing | RAM |
|---|---|---|---|---|
| `kvm-rhel` (AlmaLinux 9.4) | `kernel-rhel.yml` | database | the BLS entry `grubby` rewrote, **and** `GRUB_CMDLINE_LINUX`, which is what the *next* kernel inherits | 4096 MiB |
| `kvm-ubuntu` (Ubuntu 24.04) | `kernel-ubuntu.yml` | throughput | `/etc/default/grub.d`, in sort order, so you can see `99-canon-kernel.cfg` land after the cloud image's `50-cloudimg-settings.cfg` | 2048 MiB |
| `kvm-suse` (Leap 15.6) | `kernel-suse.yml` | low-latency | the file the **generator** wrote, not the one the role edited — on SUSE, editing `/etc/default/grub` and stopping there changes nothing | 2048 MiB |
| `kvm-amazon` (AL2023) | `kernel-amazon.yml` | container-host | **both** grub keys, because AL2023 reads `_DEFAULT` and `grubby --remove-args` blanks the other one (A31) | 2560 MiB |

```bash
./vms/up.sh kvm-suse
```

```bash
ansible-playbook -i inventory/kernel-vms.yml kernel-suse.yml
```

```bash
tests/kernel-reboot.sh kvm-suse
```

```bash
./vms/down.sh kvm-suse
```

`make lab2-vm-suse` does the first two together; `make lab2-kernel-reboot VM=kvm-suse` and `make lab2-vms-down VM=kvm-suse` do the rest.

`down.sh` keeps the disk, so booting that VM again **resumes** it — about 13 seconds, already tuned, which is what makes stopping one between sessions cheap. `./vms/down.sh --clean kvm-suse` throws the disk away instead and the next boot starts from the distribution's untouched image. That resume path is also where `RESEARCH.md` A40 was hiding: `up.sh` used to wait, on every boot, for a cloud-init sentinel that cloud-init only ever writes once.

Measured this way, one VM at a time, with nothing else booted:

| VM | Applied | Rebooted | Drift repaired (phase 3b) | Independently checked |
|---|---|---|---|---|
| `kvm-ubuntu` | `ok=40 changed=8` | 5 checks pass | `net.core.somaxconn` 65535 → 65536 by hand, put back | THP `always [madvise] never`; the drop-in beat `50-cloudimg-settings.cfg` |
| `kvm-suse` | `ok=43 changed=8` | 6 checks pass | `vm.stat_interval` 120 → 121 by hand, put back | 8 arguments pending → active; `grub.cfg` written by `grub2-mkconfig` at the timestamp the evidence prints |
| `kvm-amazon` | `ok=46 changed=9` | 5 checks pass | `vm.max_map_count` 262144 → 262145 by hand, put back | `GRUB_CMDLINE_LINUX` **absent**, `_DEFAULT` carrying all three arguments — A31, on screen |
| `kvm-rhel` | `ok=44 changed=8` | 10 checks pass, including the kernel upgrade | `vm.swappiness` 1 → 2 by hand, put back | 5.14.0-427 (9.4) → **5.14.0-687** (9.8), every managed argument inherited, 1GB huge page actually reserved |

Each host drifts a *different* key, because the four profiles share almost nothing — phase 3b picks one out of the file the role actually wrote on that host rather than naming one in advance.

Only the RHEL run included phase 4. `SKIP_UPGRADE=1` skips it, and the summary then says so rather than claiming a result it did not produce — it used to claim it (`RESEARCH.md` A36).

The four playbooks are not four copies of the tuning. Each is an `import_playbook: kernel.yml` with `kernel_target` set to its host — one copy of the bootstrap check, the role call and the summary, four entry points into it — followed by a read-only play that prints that family's artifact. `kernel.yml --limit kvm-suse` applies exactly the same tuning; what it does not do is show you *which of the four mechanisms* was used, which is the whole claim the role makes.

### All four

```bash
./vms/up.sh
```

Four QEMU virtual machines booting the distributions' own public cloud images under Hypervisor.framework — their own kernel, their own bootloader, so `reboot` means what it says. Free, and about 15 seconds each to boot.

```bash
tests/kernel-reboot.sh
```

Five phases: **apply** (arguments written, reported `PENDING` — correct, and not yet proof of anything), **reboot** (the role reboots, re-reads `/proc/cmdline`, and the test then verifies it again from outside Ansible), **re-apply** (`changed=0` against a live, tuned kernel), **runtime drift** (change a sysctl by hand with `sysctl -w`, leaving the file correct, and require the next converge to *put it back* rather than merely report it — `RESEARCH.md` A39), and **a new kernel** (install one, boot into it, observe what survived, re-apply, require every argument active).

What comes back after the reboot:

| VM | Mechanism | Active in `/proc/cmdline` | Independently checked |
|---|---|---|---|
| AlmaLinux 9.4 | `grubby` + BLS | `transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=1` | THP moved `[always]` → `[never]` |
| Ubuntu 24.04 | `99-` drop-in | `transparent_hugepage=madvise` | THP `[madvise]` — the drop-in beat the cloud image's `50-cloudimg-settings.cfg` |
| openSUSE Leap 15.6 | `grub2-mkconfig` | all 8 low-latency arguments | THP `[never]` |
| Amazon Linux 2023 | `grubby` + BLS | `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all psi=1` | booted 6.1.186 |

`vm.swappiness` is checked too, because layer 1 comes back by a **different** mechanism (`systemd-sysctl` re-reading `/etc/sysctl.d`) and one surviving does not imply the other did.

Rebooting for real found **six** bugs the container tests structurally could not. Three in the role's logic: the strict sysctl check ran *before* the modules that provide those keys were loaded (A27); the verifier printed its pre-reboot numbers *after* rebooting (A28); and the role reported `changed` on **every run** of the entire RHEL family, because the grubby task was written `changed_when: true` (A30) — the exact anti-pattern `examples/idempotence/` exists to demonstrate, in this repository's own role.

Two specific to Amazon Linux, and neither visible anywhere but a real AL2023 host (A31): it populates `GRUB_CMDLINE_LINUX_DEFAULT` where RHEL 9 populates `GRUB_CMDLINE_LINUX`, and `grubby --remove-args` **blanks the whole of `GRUB_CMDLINE_LINUX`** there — so the role wrote its arguments into the variable AL2023 ignores and then erased them with its own next task. The reboot test passed the entire time, because grubby had done its half correctly; the half being erased is the one that matters after the next `dnf update kernel`.

And one in the harness: `hugepages=1` was active in `/proc/cmdline` with **zero pages actually reserved**. A hugepage count is a *request* — the kernel reserves what it can find contiguously and carries on with less — so every check that stops at "is the argument active?" calls that a success. The verifier now compares the request with the reservation.

All six are in [`RESEARCH.md`](../../RESEARCH.md).

```bash
./vms/down.sh --clean
```

## Step 10 — the same role, on real AWS

```bash
cd aws && terraform apply -var "ssh_ingress_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```

Four EC2 instances, one per distribution family, tuned by the same role and the same profiles. **This one costs money** — about 0.07 USD an hour for four `t4g.small`, and nothing once destroyed. No `make` target applies it; see [`aws/README.md`](aws/README.md) for the cost table and what is different about EC2 (the AMI's own boot arguments, a hypervisor reboot, and Amazon Linux on the platform it belongs on).

The integration worth noticing: the instances are tagged `KernelProfile`, and [`inventory/aws_ec2.yml`](inventory/aws_ec2.yml) reads that tag into `kernel_profile` with `compose`. The workload posture is decided once, by the thing that creates the machine, and nothing else keeps a copy to drift from.

## Step 11 — the production inventory: found by tag, reached without SSH

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
