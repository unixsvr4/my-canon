# Ansible patterns

Lab: [`labs/lab2-ansible`](../labs/lab2-ansible/).

## 1. Role design

A role is reusable when it can be dropped into a new estate and configured entirely through data. The rules used here:

| Rule | Mechanism | Lab 2 |
|---|---|---|
| one job per role | fleet logic (batches, gates) lives in plays, not roles | `baseline`, `patch` vs. `patch.yml` |
| every input declared with a safe default | `defaults/main.yml` | all `baseline_*` variables |
| inputs validated before any task runs | `meta/argument_specs.yml` + `tasks/validate.yml` | 8 rejection tests |
| variables prefixed with the role name | `baseline_*`, including `register:` results | enforced by ansible-lint |
| collections merge without clobbering defaults | `x` (role-owned) + `x_extra` (caller-owned), combined in tasks | `baseline_sysctl_extra` |
| no host-type conditionals inside the role | tiers differ via `group_vars` | web, db, app |
| no hidden composition | `dependencies: []` | both roles |
| handlers namespaced | `Baseline \| reload sshd` | handlers/main.yml |
| portable across platforms | check facts (`service_mgr`), don't assume directories or binaries exist | containers, VMs, bare metal |

## 2. Idempotence

**A second run against a correct host must report zero changes.** Otherwise the run restarts services for no reason and can't distinguish a correct host from a drifted one, so its drift report is noise.

| Do | Instead of |
|---|---|
| declarative modules (`package`, `user`, `group`, `template`, `lineinfile` with `regexp`) | `command`/`shell` that always reports changed |
| `state: present` in baselines | `state: latest`: a different result on different days |
| template the whole file; one owner per file | `sed -i`, `echo >>` |
| `creates:` / `removes:` on unavoidable commands | an unguarded command |
| handlers for restarts | a restart task that runs every time |
| deterministic rendering: `dictsort`, no timestamps or run ids | iterating dicts in varying order; "last updated" lines |
| `changed_when: false` on read-only commands, **only when truly read-only** | `changed_when: false` added to silence the linter |
| one file owning a set of keys | per-key edits that leave removed keys behind |

**Prove it, don't assume it.** `tests/idempotence.sh` converges, runs again and fails on any change, listing the tasks. Linting isn't a substitute: against the six anti-patterns in `examples/idempotence/`, ansible-lint flags five (mostly `no-changed-when`, a symptom rule that is easily silenced the wrong way) and misses the per-run timestamp entirely. The converge-twice test catches all six.

## 3. Safety in the role itself

- **`validate:` on files that can lock you out**: `sshd -t -f %s`, `visudo -cf %s`. The candidate file is checked before it replaces the real one.
- **Verify the effective configuration.** A file with correct content can still be overridden: AlmaLinux 9 ships an sshd drop-in that sets `PermitRootLogin yes` and sorts before a `50-` or `99-` hardening file, and the first value wins. Asserting on `sshd -T` catches it; asserting on the file doesn't.
- **Flush handlers before verification**, so the check sees the reloaded service.
- **Skip verification in check mode.** Nothing was converged, so it would fail on every drifted host.

## 4. Inventory

- **Three independent axes**: what it is (`rhel9`), what it runs (`web`/`db`/`app`), when it can be touched (`canary`, `window_*`, `never_unattended`). Intersections compose: `--limit 'web:&window_sat_2200'`.
- **Dynamic inventory in production** (vCenter, the CMDB, `aws_ec2` with `keyed_groups`). A static list is a drift surface: an unlisted server is never patched or checked. Reconcile inventory against the network periodically.
- **Precedence used deliberately**: role defaults < `group_vars/all` < `group_vars/<tier>` < `host_vars`. `host_vars` are rare, because each one is a permanent difference between supposedly identical servers.

## 5. Secrets and credentials

- A **dedicated automation account**, key-based, `become` through a **scoped** sudoers rule. It can only be driven from CI, not from a laptop, and is audited like the highly privileged identity it is.
- **Secrets pulled at runtime** from a secret manager (HashiCorp Vault, AWS Secrets Manager) through lookups. Rotation needs no code change.
- **`ansible-vault`** only for the few values that must live in git, with the vault password supplied by the CI runner.
- **`no_log: true`** on every task that handles a credential, or the run log becomes a secret store.
- **Windows**: WinRM over HTTPS with Kerberos. Not Basic, and not CredSSP (unconstrained delegation).

## 6. Testing layers

| # | Layer | Catches |
|---|---|---|
| 1 | `ansible-lint` (production profile), `--syntax-check` | style, FQCNs, risky patterns |
| 2 | input-contract tests | bad variables reaching a fleet |
| 3 | converge + **idempotence** (this repo's script, or Molecule) | roles that can't tell right from wrong |
| 4 | `--check --diff` against real hosts, limited | what the run *would* do to production |
| 5 | staging fleet built by the same roles | integration effects |
| 6 | canary in production with a real health gate | everything else |

Check mode has a known limit: a task whose result depends on an earlier task's *change* can report nonsense. Write irreversible tasks to be check-mode-safe, and treat a clean `--check` as one layer, not proof.

## 7. Rolling changes and patching at scale

The play shape (lab 2 `patch.yml`):

```text
serial: [1, 5, "25%"]   max_fail_percentage: 0 (canary) / low threshold after
per batch:  pre-flight ─► drain (delegate_to LB) ─► patch (pinned repo snapshot) ─► reboot only if required
            ─► health gate (service, port, app endpoint, cluster membership; retries/until)
            ─► return to pool, or quarantine with diagnostics (block/rescue/always)
after run:  per-host records ─► report; failures ─► retry file ─► --limit @retry
```

Details that separate a working patch process from a risky one:

- **A `rescue`d failure doesn't count toward `max_fail_percentage`.** Fail the host again outside the block, or the run marches into the next batch (verified on ansible-core 2.21).
- **Pin the repository to a snapshot for the cycle.** Otherwise host 1 and host 200 end up on different package sets.
- **Reboot only when required** (`needs-restarting -r`, or running kernel ≠ newest installed), and after reboot verify the **running** kernel. A host that boots the old kernel looks healthy and isn't patched.
- **Keep the previous kernel** in the same run, so a failed boot has a bootloader fallback.
- **`forks`** sized to what the control node, the network and the repository mirror can sustain. Too many forks turns a patch run into a load test.
- **Remediation paths**: `dnf history undo <id>` for a bad transaction, snapshot revert for a VM, the previous kernel from the bootloader via the BMC console for physical hosts, and rebuild from PXE when a host is truly gone.

### Replacing a spreadsheet-driven process

A hand-maintained patch spreadsheet fails in four ways, and only one of them is speed:

| Problem | Why | Fixed by |
|---|---|---|
| stale on arrival | typed once; can't know about last week's new server | generated inventory |
| unverifiable | a green cell means someone *believed* it was patched | status measured from the host by the run |
| inconsistent | order, flags and checks vary by who has the shift | identical code for every host |
| doesn't scale | effort grows with fleet size | effort is flat |

**The run produces the record.** Per-host status, kernel before/after, reboot, packages and timing are written as each host finishes, so an aborted run still reports what it did. That record doubles as compliance evidence, as trend data (the same hosts failing every cycle point to a root cause), and as an exception list that keeps unreachable hosts visible. Once patching is cheap and safe, teams patch more often, and smaller deltas mean fewer surprises.

## One role, several distributions

The rule is the same one `platform-translation.md` gives for a second cloud: **keep the interface identical and write a per-platform implementation behind it.** Do not build one abstraction that tries to be every platform, because it becomes the lowest common denominator plus a pile of conditionals.

`roles/kernel` is the worked example. Its inputs are the same everywhere; `vars/family-RedHat.yml`, `family-Debian.yml` and `family-Suse.yml` supply the mechanism, selected with `first_found` on `ansible_facts['os_family']` — with the *distribution* file tried before the *family* file, so Amazon Linux inherits RHEL's mechanics and overrides only what differs. An unsupported platform fails on the first task with a message naming it, rather than three tasks later with "file not found".

Two things that generalise beyond kernel tuning:

- **Those platform-loading tasks are tagged `always`.** They are prerequisites of every other tag, not a section of their own; without it, `--tags one_section` fails with an undefined variable (`RESEARCH.md` A19).
- **`/bin/sh` is not portable for a shell task.** It is dash on Debian and Ubuntu, and dash has no `set -o pipefail` — which ansible-lint's `risky-shell-pipe` requires. All the mainstream server distributions ship bash, so `executable: /bin/bash` is the portable choice, which is the opposite of the usual advice and true for a specific reason (A17).

## Declarative means removals work

A role that can add a setting and cannot remove one is not declarative, and the gap is easy to miss because adding is what gets tested. Three shapes, in order of preference:

1. **Own a whole file.** One templated file per concern — the sysctl drop-in, the module list, the limits file. Remove a key from the variables and the next run removes the line. This is why the `baseline` and `kernel` roles template a single file rather than using one module call per key: the per-key module is idempotent but leaves removed keys behind forever, which is invisible drift.
2. **Own a drop-in in someone else's directory.** Same benefit, and it never has to parse a file you do not control.
3. **Edit a shared file** — only when the distribution gives you no drop-in. Then you need a **key-aware merge** (strip what you own, append your current set, leave the vendor's alone) *and* a record of what you owned last time, because your current set can become empty. `roles/kernel` writes a marker comment for exactly that (A25).

## Verify the effective state, not the file

Two examples in this repository, and the pattern is worth applying to anything with a read order or a load step:

- `sshd -T` after writing a drop-in, because sshd takes the **first** value it reads and a vendor file can sort earlier (A1).
- `/proc/cmdline`, `/proc/sys` and `/sys` after kernel tuning, because a file can be correct while the running kernel is not — and the three outcomes are different: **active** is fine, **pending a reboot** is a scheduling decision, and **written, loaded, and still not the running value** is a failure, because something later in the read order owns that key.

## Testing layers, and what each one cannot do

Four rungs, cheapest first. The rule is that each rung tests something the one below it **cannot**, otherwise it is not worth its runtime:

| Rung | Tests | Blind to |
|---|---|---|
| `ansible-lint` (production profile) | style, FQCNs, naming, the shapes that correlate with bugs | whether anything works |
| **containers** | the right file, in the right place, on several distributions; idempotence; the input contract | anything about a kernel, a reboot, or a service manager — a container has neither its own kernel nor systemd |
| **virtual machines** | that the configuration takes EFFECT: a boot argument in `/proc/cmdline`, a reload on boot, a reboot survived, a kernel upgrade lived through | the platform's own quirks — an AMI's existing boot arguments, a hypervisor reboot, cloud-init's ordering |
| **the real platform** (EC2, vSphere, hardware) | all of it | nothing, and it costs money and time, so it runs periodically rather than per commit |

The `kernel` role is the worked example, and the numbers make the argument: the container rung runs in 40 seconds and catches the file mechanics on four distributions; the VM rung takes 15 minutes and caught **six** bugs the container rung structurally could not, including a role that reported `changed` on every single run of an entire distribution family (`RESEARCH.md` A30) and one that wrote its settings into a variable the distribution ignores and then erased them (A31).

Two lessons that generalise beyond kernels:

- **A container's accommodations are not free.** `kernel_sysctl_apply: false` and `kernel_sysctl_strict: false` are correct for a container and they switch off exactly the checks that would have caught A27. Write them down as accommodations, keep the defaults honest, and make sure some rung runs with them ON.
- **"It answered" is not "it is ready."** cloud-init starts sshd and *then* runs its final stage, so a play can start while the interpreter it needs is still installing — and if that install fails, cloud-init cheerfully carries on and writes your readiness marker anyway (A32). Wait for the thing you actually need, and check it.
