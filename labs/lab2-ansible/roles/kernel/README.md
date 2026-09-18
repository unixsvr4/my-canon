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
| **Amazon Linux 2023** | same BLS + grubby as RHEL 9 | none needed | The mechanism is not the problem — **the lifecycle is**. See below. |

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
| `DIFFERS` | loadable at runtime, written, loaded, and still not the running value | a **failure** — something later in sysctl's read order is overriding it |

```text
CMDLINE  PENDING  transparent_hugepage=never  (reboot required)
CMDLINE  PENDING  hugepages=8  (reboot required)
SYSCTL   ok       vm.swappiness = 1
SYSCTL   DIFFERS  vm.max_map_count  want=262144 running=65530
SYSCTL   ABSENT   kernel.sched_migration_cost_ns  (not in this kernel)
THP      state    always [madvise] never
```

This is the same idea as lab 1's `verify-env.py`: "the apply succeeded" and "the environment is correct" are two different claims. Here they are "the files are right" and "the kernel is running it".

The role **never reboots by default** — a role that reboots when you did not ask is a role nobody runs on a Friday. `kernel_reboot_ok: true` allows it, and then a second check confirms the arguments really are in `/proc/cmdline` afterwards, because "we rebooted" is not the same as "it is active".

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
| `kernel_profile` in the inventory | from the `KernelProfile` tag Terraform stamps, via lab 2's `aws_ec2` inventory and lab 3's `cloud-hosts.yml` |
