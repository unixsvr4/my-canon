# `kernel` — kernel tuning that survives a reboot, on four distributions

One role, one interface, four persistence mechanisms. RHEL 9, Ubuntu 24.04, SLES 15 and Amazon Linux 2023 each store kernel boot arguments somewhere different, and getting that wrong produces the worst kind of failure: the change is applied, the play is green, and the setting is not in effect — either now or after the next kernel update.

## Why a role, when it is "just a sysctl"

Because it is not just a sysctl. "Tune the kernel" is three different problems wearing one hat, and they persist in three different places:

| Layer | Where it lives | When the kernel reads it | The failure if you use the wrong layer |
|---|---|---|---|
| **1. Runtime parameters** | `/etc/sysctl.d/90-canon-kernel.conf` | now, and on every boot | none — this is the layer everyone knows |
| **2. Load-time options** | `/etc/modprobe.d/`, `/etc/modules-load.d/`, `/etc/security/limits.d/` | when the module loads / at login | set it at runtime and it is accepted and ignored |
| **3. Boot arguments** | the bootloader — **four different mechanisms** | only at boot | **no runtime equivalent exists at all** |

Three settings that make the distinction concrete:

- **`transparent_hugepage=never`** — the one every database vendor documents. There is no sysctl for it. The runtime interface is `/sys/kernel/mm/transparent_hugepage/enabled`, which resets on every boot, so the durable answer is a kernel command-line argument. Teams that "fixed" THP with an `rc.local` echo find it back after the next kernel update.
- **`nf_conntrack`'s `hashsize`** — `nf_conntrack_max` is a sysctl; the number of hash buckets is not. It can only be set as the module loads. Leave it default with a million tracked connections and every lookup walks a long chain: softirq CPU climbs with no obvious cause.
- **1GB hugepages** — 2MB pages can be reserved at runtime via `vm.nr_hugepages`. 1GB pages cannot: the allocator needs contiguous memory that only exists before userspace has fragmented it. Reserve at boot or not at all.

## The four mechanisms

This is the part that is genuinely different per distribution. The role's interface never changes; `vars/family-*.yml` selects the implementation, exactly as [`docs/platform-translation.md`](../../../../docs/platform-translation.md) prescribes for a second cloud — one interface, a per-platform implementation behind it, and no single clever abstraction trying to be both.

| Family | Mechanism | Generator | The trap |
|---|---|---|---|
| **RHEL 9** / AlmaLinux / Rocky | `grubby --update-kernel=ALL` for the existing BLS entries in `/boot/loader/entries/`, **and** `GRUB_CMDLINE_LINUX` in `/etc/default/grub` for kernels installed later | none needed | Do only the first and **the tuning disappears at the next `dnf update kernel`** — the host reboots into the new kernel with the distribution's defaults and there is no configuration change to blame. Do only the second and nothing happens until a kernel update. |
| **Ubuntu 24.04** / Debian 12 | a `99-` drop-in in `/etc/default/grub.d/` | `update-grub` | `grub-mkconfig` sources `/etc/default/grub` and *then* `/etc/default/grub.d/*.cfg`, as shell — so **the last assignment wins**. Every Ubuntu cloud image and AMI ships `50-cloudimg-settings.cfg`, which sets `GRUB_CMDLINE_LINUX_DEFAULT`. Edit `/etc/default/grub` and the cloud image overrides you afterwards. |
| **SLES 15** / openSUSE | `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` | `grub2-mkconfig` — **mandatory** | There is no grubby, so writing the file alone changes nothing. YaST writes the same file and reformats it; on SLE Micro, `transactional-update grub.cfg` and a reboot into the new snapshot. |
| **Amazon Linux 2023** | same BLS + grubby as RHEL 9, but `GRUB_CMDLINE_LINUX_**DEFAULT**` | none needed | **Not the same key as RHEL 9**, and `grubby --remove-args` *blanks* `GRUB_CMDLINE_LINUX` here. Both measured on a real instance — see below. The lifecycle is a second problem again. |

The sourcing order that decides the Ubuntu case was verified rather than assumed, by reading the script that does it:

```bash
docker run --rm ubuntu:24.04 sh -c 'apt-get update -qq && apt-get install -y -qq grub2-common && sed -n "160,169p" /usr/sbin/grub-mkconfig'
```

```text
if test -f ${sysconfdir}/default/grub ; then
  . ${sysconfdir}/default/grub
fi
for x in ${sysconfdir}/default/grub.d/*.cfg ; do
  if [ -e "${x}" ]; then . "${x}" ; fi
done
```

This is the same class of bug as the sshd drop-in in the [`baseline`](../baseline/README.md) role, with the ordering **reversed**: sshd takes the *first* value it reads, a sourced shell file keeps the *last*. Knowing which way round a given configuration system works is the whole job.

### Amazon Linux is in the RHEL family and still different

Two facts, both found on a real AL2023 instance and neither visible in a container:

1. **AL2023 populates `GRUB_CMDLINE_LINUX_DEFAULT` and leaves `GRUB_CMDLINE_LINUX` empty.** RHEL 9 and AlmaLinux do the exact opposite — they fill `GRUB_CMDLINE_LINUX` and have no `_DEFAULT` line at all. So "the key a future kernel inherits from" is not the same key for two members of one family.
2. **`grubby --update-kernel=ALL --remove-args=...` blanks the whole of `GRUB_CMDLINE_LINUX` on AL2023**, not just the named keys:

```text
after our write:      GRUB_CMDLINE_LINUX="probe_marker=1"
after grubby remove:  GRUB_CMDLINE_LINUX=""
```

On AlmaLinux 9 the same command leaves that line untouched, and `_DEFAULT` survives on AL2023.

Together those meant the role wrote its arguments into the variable AL2023 ignores, and then **its own next task erased them** — so the file churned on every run and the future-kernel protection was never really there. `vars/distro-Amazon.yml` now targets `_DEFAULT`, which is both the key AL2023 reads and the one grubby leaves alone.

Worth noticing *how* this surfaced: the reboot test had been **passing** throughout, because grubby had done its half correctly and the BLS entries were right. What was being erased is the half that only matters after the next `dnf update kernel` — the failure that would have shown up weeks later, on a host nobody was watching, with no configuration change to blame. It was phase 3, "a re-apply must change nothing", that caught it.

## Amazon Linux: the mechanism is right and the answer is still wrong

Apply this role to a running EC2 instance in an Auto Scaling group and the tuning is correct until the next scale-out, instance refresh, spot interruption or AZ rebalance — at which point a fresh instance boots from the AMI with none of it. The fleet then has two populations that behave differently under load, and the difference is invisible to any dashboard that aggregates them. It is the same class of problem as a `%post` block in lab 3's kickstart: a one-time change that becomes permanent invisible drift.

Where it belongs instead:

1. **Baked into the AMI.** EC2 Image Builder runs this role in the build pipeline, reboots once during the build so the boot arguments are already active in the image, and the AMI is then immutable and versioned. Set `kernel_fail_on_reboot_required: true` there, so an image that still needs a reboot is a **failed build** rather than a surprise later.
2. **User data**, for the layers that need no reboot — cloud-init runs it on first boot, so layers 1 and 2 are live before the instance joins a target group.
3. **SSM State Manager** on a schedule, as enforcement and drift detection rather than as the primary mechanism.

`inventory/group_vars/aws_ec2.yml` therefore sets `kernel_manage_bootloader: false` for discovered EC2 instances, with the reasoning next to it.

## Workload profiles

`kernel_profile` selects a posture. Every value in [`vars/profiles.yml`](vars/profiles.yml) carries a comment saying what it does and what breaks without it, because a tuning file nobody can explain is a tuning file nobody dares change.

| Profile | For | The settings that matter most |
|---|---|---|
| `general` | any server | syncookies, no ICMP redirects, `kptr_restrict`, protected symlinks, `panic=10` |
| `throughput` | proxies, ingest, CDN | **BBR + `fq`** (BBR needs `fq` to pace, or it underperforms for no visible reason), socket buffers sized for the bandwidth-delay product, `somaxconn=65535`, `nf_conntrack` **hashsize as a load-time option** |
| `database` | PostgreSQL / MySQL / MongoDB | **`transparent_hugepage=never`**, 1GB hugepages at boot, `dirty_bytes` rather than `dirty_ratio`, `swappiness=1` (not 0), `overcommit_memory=2`, `memlock unlimited` |
| `low-latency` | market data, real-time media | `isolcpus` + `nohz_full` + `rcu_nocbs` **all naming the same cores**, C-states capped, `idle=poll`, NMI watchdog off, busy-polling |
| `container-host` | Kubernetes nodes | inotify limits, `pid_max`, **ARP `gc_thresh3`**, `br_netfilter` loaded at boot, cgroup v2 forced, `psi=1` |

Every one of those is a default that breaks at scale with a recognisable signature. `net.ipv4.neigh.default.gc_thresh3` is the clearest: above roughly a thousand pods per node the default of 1024 starts evicting live neighbours, the node logs `neighbour: arp_cache: neighbor table overflow`, and traffic to random pods fails intermittently.

`vm.swappiness: 1` rather than `0` in the database profile is deliberate. Zero forbids swapping entirely, so a memory spike goes straight to the OOM killer, which picks the biggest process — the database. One keeps swap as a last resort without using it routinely.

## The interface

```yaml
- hosts: db
  roles:
    - role: kernel
      vars:
        kernel_profile: database
        # Merged OVER the profile, never replacing it.
        kernel_sysctl_extra:
          vm.nr_hugepages: 4096
        kernel_cmdline_extra:
          - intel_iommu=on
```

The `_extra` variables exist because Ansible **replaces** dicts and lists at higher precedence rather than merging them: a `group_vars` file that set `kernel_sysctl` directly would silently drop every profile value. The role owns the profile, the caller owns `_extra`, and `tasks/main.yml` combines them once. Same pattern as the `baseline` role.

Full contract, with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

## What the role refuses to do

Bad input is rejected before anything is written, and the message says what is wrong:

| Rejected | Why |
|---|---|
| a `kernel_profile` that does not exist | `argument_specs` lists the valid ones in the error |
| **a sysctl key this kernel does not have** | see below — the single most useful check in the role |
| a boot argument containing a space | the kernel splits its command line on spaces, so it would become two arguments and the second would be ignored. Quoting does not help; this is the kernel's own parser |
| `kernel_sysctl_apply: true` with no `sysctl` binary | a promise the role cannot keep |
| a `limits` entry for an item PAM does not know | it would be written and silently ignored |

The sysctl key check compares every configured key against `/proc/sys`, which mirrors the key namespace as a directory tree. A key that is missing is missing for one of three reasons, all of them real:

- **removed from the kernel** — `net.ipv4.tcp_tw_recycle`, gone since 4.12, still in tuning guides everywhere (and still confused with `tcp_tw_reuse`, which is safe and is in the `throughput` profile)
- **needs a build option** — `kernel.sched_migration_cost_ns` requires `CONFIG_SCHED_DEBUG`
- **its module is not loaded** — `net.netfilter.nf_conntrack_max` does not exist until `nf_conntrack` is, which is why `tasks/modules.yml` runs *before* `tasks/sysctl.yml`

Writing it anyway is worse than refusing: depending on the distribution, `sysctl --system` either skips it silently or **aborts the file**, so the keys after it are never applied either.

## Removing a setting has to work too

This is the part most implementations get wrong, because the wrong version looks right. Appending the arguments passes any "is my setting there?" test and quietly leaves `hugepages=99 hugepages=8` on the boot line. The kernel takes the last value for most duplicated parameters, so it appears to work — until it is a parameter the kernel reads first.

So on the RHEL family the role does a **key-aware merge**: it strips every argument whose key it manages, then appends its current set, preserving the distribution's own arguments. And because "the keys it manages" can become *empty* — switch a host from `database` to `general` and the role suddenly owns no boot arguments — it records what it owns in a marker comment and reads it back:

```text
# canon-kernel-managed: transparent_hugepage default_hugepagesz hugepagesz hugepages
GRUB_CMDLINE_LINUX="crashkernel=1G-4G:192M resume=/dev/mapper/rhel-swap rd.lvm.lv=rhel/root console=ttyS0,115200 transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=8"
```

Declarative means removals work, and removals need a record of what you previously owned. The Debian drop-in needs no marker: everything it manages lives in its own file, so rewriting that file with fewer arguments removes them by construction. That is the real argument for drop-in directories over editing shared files — and the reason the two implementations differ instead of sharing one abstraction.

## Verification: desired state versus running kernel

Every task can succeed while the kernel runs something else. `tasks/verify.yml` reads `/proc/cmdline`, `/proc/sys` and `/sys`, and reports three outcomes — only one of which is a failure:

| Outcome | Meaning | Treated as |
|---|---|---|
| `active` | configured and running now | fine |
| `PENDING` | configured, needs a reboot | a **report** — the reboot is a scheduling decision |
| `DIFFERS` | loadable at runtime, written, and not the running value | first **repaired**, then a **failure** if it survives the repair — see below |

```text
CMDLINE  PENDING  transparent_hugepage=never  (reboot required)
CMDLINE  PENDING  hugepages=8  (reboot required)
SYSCTL   ok       vm.swappiness = 1
SYSCTL   DIFFERS  vm.max_map_count  want=262144 running=65530
SYSCTL   ABSENT   kernel.sched_migration_cost_ns  (not in this kernel)
THP      state    always [madvise] never
```

This is the same idea as lab 1's `verify-env.py`: "the apply succeeded" and "the environment is correct" are two different claims. Here they are "the files are right" and "the kernel is running it".

`DIFFERS` has two causes that look identical in the report and need opposite answers, so the role separates them by acting rather than by guessing. If the collected state differs, it runs `sysctl --system` and re-reads:

- someone ran **`sysctl -w`** during an incident and the file on disk was right the whole time. The reload corrects it, the run reports `changed`, and that is what a converge is for. Nothing on disk changed, so the write task reported no change and the reload handler was never notified — which is exactly why this cannot be left to the handler (`RESEARCH.md` A39)
- a **drop-in that sorts after ours**, a systemd unit or a container runtime genuinely owns that key. `sysctl --system` replays every file in the real read order, so the other file wins again, the value is still wrong, and the assert fails naming the real cause

The reload is gated on the collected state, so it cannot fire on a converged host and idempotence is intact.

The role **never reboots by default** — a role that reboots when you did not ask is a role nobody runs on a Friday. `kernel_reboot_ok: true` allows it, and then a second check confirms the arguments really are in `/proc/cmdline` afterwards, because "we rebooted" is not the same as "it is active".

## Proving it three ways

"It survives a reboot" is the whole claim of layer 3, and a container cannot test it: a container shares the host's kernel, so `/proc/cmdline` inside one is the host's and every boot argument reads `PENDING` forever. So the role is proven on three rungs, each testing what the one below it cannot:

| Rung | Proves | Cost | Time |
|---|---|---|---|
| **4 containers** — `tests/kernel-multidistro.sh` | the right file, in the right place, on four distributions; and idempotence | none | about 40s |
| **4 QEMU VMs** — `tests/kernel-reboot.sh` | a real kernel **boots with those arguments**, survives a reboot, has its **runtime drift repaired** by a converge, and carries the tuning onto a **newly installed kernel** | none | about 15 min |
| **4 EC2 instances** — [`../../aws/`](../../aws/) | the same, on the hardware and the AMIs that run the workload | about 0.07 USD/hour | about 20 min |

### The reboot, measured

```bash
./vms/up.sh && tests/kernel-reboot.sh
```

or one distribution at a time, which is how it fits on a laptop — the four guests want about 10.7GB between them, and each has an entry point of its own that ends by printing its family's artifact:

```bash
./vms/up.sh kvm-suse && ansible-playbook -i inventory/kernel-vms.yml kernel-suse.yml
```

```bash
tests/kernel-reboot.sh kvm-suse && ./vms/down.sh kvm-suse
```

`kernel-rhel.yml`, `kernel-ubuntu.yml`, `kernel-suse.yml` and `kernel-amazon.yml` each import `kernel.yml` with `kernel_target` set to one host, so the tuning has exactly one implementation and four doors into it.

Four VMs booting the distributions' own public cloud images under QEMU with Hypervisor.framework — their own kernel, their own bootloader, so `reboot` means what it says. Before the reboot every managed argument is `PENDING`. After it, read back from `/proc/cmdline` **outside Ansible**:

| VM | Mechanism | Active after the reboot | Independent evidence |
|---|---|---|---|
| AlmaLinux 9.4 | `grubby` + BLS | `transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=1` | THP moved from `[always]` to `always madvise [never]` |
| Ubuntu 24.04 | `99-` drop-in | `transparent_hugepage=madvise` | THP `always [madvise] never` — the drop-in beat the cloud image's `50-cloudimg-settings.cfg`, which is the whole reason for the `99-` prefix |
| openSUSE Leap 15.6 | `grub2-mkconfig` | all 8 low-latency arguments | THP `[never]`; on this family writing the file alone would have changed nothing |
| Amazon Linux 2023 | `grubby` + BLS | `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all psi=1` | booted 6.1.186 |

`vm.swappiness` is checked too, because layer 1 persists by a **different** mechanism — `systemd-sysctl` re-reading `/etc/sysctl.d` on boot — and one surviving does not imply the other did.

### What rebooting for real found

Bugs that the container tests could not have caught, all now in [`RESEARCH.md`](../../../../RESEARCH.md):

- **The strict sysctl check ran too early** (A27). It was in `validate.yml`, which runs *before* `modules.yml` — and `net.netfilter.nf_conntrack_max` does not exist until `nf_conntrack` is loaded. The ordering comment in `tasks/main.yml` says modules must come first *for exactly that reason*, and the check enforcing it was itself jumping the queue. It now lives in `sysctl.yml`.
- **The role was not idempotent on the RHEL family** (A30). The grubby task was written `changed_when: true`, so every run reported a change on every RHEL-family host — the exact anti-pattern [`examples/idempotence/`](../../examples/idempotence/) exists to demonstrate, in this repository's own role. It now compares the boot entry's argument set before and after.
- **Amazon Linux was writing to the wrong variable, and then wiping it** (A31, above).
- **The report was stale** (A28). The role collected the state, rebooted, and then printed the numbers from *before* the reboot — `boot_args_pending=4` about a host that had just come back with all four active. The collection is now `verify-collect.yml` and runs twice.
- **`hugepages=1` was active with zero pages reserved.** A hugepage count is a *request*: the kernel reserves what it can find contiguously at boot and carries on with less. `/proc/cmdline` still shows the argument, so a check that stops at "is it active?" reports success while the database gets small pages. The verifier now compares the request with `/sys/kernel/mm/hugepages/.../nr_hugepages` and fails on a shortfall.

- **Drift was detected and not repaired** (A39). Two sysctls changed by hand with `sysctl -w` made the next converge *fail* rather than fix them, blaming a drop-in ordering problem that did not exist — because the file was already correct, so nothing was notified and nothing was reloaded. A converge that reports drift it could have corrected is doing half the job, and naming the wrong cause is worse than reporting nothing.

That last one is the pattern this whole role is built around, one level deeper than usual: **the file was right, the argument was active, and the thing it was for still had not happened.**

### A new kernel

The fourth phase is the question a production fleet actually asks. It installs a new kernel, reboots into it, **observes** whether the tuning came along, and then re-applies the role and requires every argument active on the new kernel.

It observes rather than asserts because the answer is distribution-specific, and it is the failure the RHEL family's *two* writes exist for: `grubby` fixes the boot entries that exist **now**, and `GRUB_CMDLINE_LINUX` in `/etc/default/grub` is what a kernel installed **later** inherits from. Do only the first and the tuning disappears at the next `dnf update kernel` — with no configuration change to blame, on a host nobody was watching.

Either way, the fix is the same and the test proves it: **re-run the role.** That is what makes a scheduled converge worth having over a one-time change.

## Run it

Four containers, four distributions, four profiles. From `labs/lab2-ansible/`:

```bash
./setup-distros.sh
```

```bash
ansible-playbook -i inventory/kernel-hosts.yml kernel.yml
```

```text
ktr-rhel   (AlmaLinux 9.8, RedHat) profile=database       boot_args_pending=4 mechanism=grub-file
ktr-ubuntu (Ubuntu 24.04, Debian)  profile=throughput     boot_args_pending=1 mechanism=grub-dropin
ktr-suse   (SLES 15.6, Suse)       profile=low-latency    boot_args_pending=9 mechanism=grub-file
ktr-amazon (Amazon 2023, RedHat)   profile=container-host boot_args_pending=3 mechanism=grub-file
```

```bash
tests/kernel-multidistro.sh
```

20 assertions that each distribution got **its own mechanism's artifact** — not merely that the play went green — then a second run requiring zero changes on all four.

```bash
tests/kernel-contract.sh
```

16 cases: seven rejected inputs, and nine on the key-aware merge against a realistic vendor `/etc/default/grub` (vendor arguments preserved, stale values gone, no key twice, and removal actually removing).

Two things about the containers, both deliberate. `kernel_sysctl_apply: false`, because a container shares the host's kernel and cannot write `/proc/sys` — so the files are managed and drift-detectable while the runtime load is skipped, the same accommodation the `baseline` role makes for containers without systemd. And `kernel_sysctl_strict: false`, because `/proc/sys` inside a container is the *host's* key set, not the distribution's, so the check would be testing the wrong machine. It stays on for real hosts, and `tests/kernel-contract.sh` proves it works by turning it on with a key no kernel has any more.

There is no bootloader in a container either, so the generator step reports that it could not run and the arguments are staged — which is exactly the right behaviour in an image build, and a problem on a server.

## Production notes

| In this lab | In production |
|---|---|
| four containers | four host groups, or an Image Builder pipeline per AMI |
| `kernel_sysctl_apply: false` | left at `true`; the host owns its kernel |
| `kernel_sysctl_strict: false` | left at `true`; the check is meaningful there |
| boot arguments staged, no generator | `grubby` / `update-grub` / `grub2-mkconfig` run, and the reboot scheduled |
| reboot reported | `patch.yml`'s `serial` batching and health gate, one host at a time |
| `kernel_profile` in the inventory | from the `KernelProfile` tag Terraform stamps, via lab 2's `aws_ec2` inventory (`compose:`) and lab 3's `cloud-hosts.yml` — decided once, by the thing that creates the machine |
| four QEMU VMs | the EC2 rig in [`../../aws/`](../../aws/), or the real fleet; the role and the test are identical, only the inventory changes |
