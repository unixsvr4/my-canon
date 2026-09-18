# roles/

| Role | Purpose | Reusable because | Tested by |
|---|---|---|---|
| [`baseline/`](baseline/) | Converge a host to the OS baseline, then verify effective config | prefixed vars, `_extra` merges, enforced argument spec, no host-type conditionals, no dependencies | `tests/idempotence.sh`, `tests/input-validation.sh`, `ansible-lint` |
| [`kernel/`](kernel/) | Kernel tuning that survives a reboot: sysctls, module load options, limits, boot arguments | one interface, four per-distribution implementations selected from `vars/family-*.yml`; installs no packages | `tests/kernel-multidistro.sh`, `tests/kernel-contract.sh`, `ansible-lint` |
| [`patch/`](patch/) | Patch one host safely: pre-flight, update, conditional reboot | fleet logic (batching, gates, abort) stays in the calling play | `patch.yml` runs 1 and 2 |

## The role contract used in this repository

1. **One job per role.** `baseline` converges a host; `patch` patches one. Neither knows about batches, load balancers or other roles.
2. **Inputs are declared, defaulted and validated.** Every variable is in `defaults/main.yml` with a safe value and typed in `meta/argument_specs.yml`. Rules spanning several variables go in `tasks/validate.yml`.
3. **Variables are prefixed with the role name.** `baseline_*`, `kernel_*`, `patch_*`, including registered results. ansible-lint's `var-naming[no-role-prefix]` enforces it — and it is why the kernel role is called `kernel` rather than `kernel_tuning`: the prefix has to match the role name, and `kernel_tuning_sysctl_extra` reads worse than `kernel_sysctl_extra`.
4. **Idempotent by construction, and proven.** Modules over commands, templates over edits, handlers over restarts, `creates:` on unavoidable commands, and a second run that must report zero changes.
5. **Safe writes.** Config files that can lock you out (`sshd`, `sudoers`) are written with `validate:`.
6. **Behaviour comes from data.** No `when: inventory_hostname in groups['db']` inside a role; tiers differ via `group_vars`.
7. **No hidden composition.** `dependencies: []`; roles are combined in playbooks, where you can see it. The `kernel` role needs `procps` and does not install it, because `baseline` owns packages — it asserts the binary exists instead, with a message saying which role to run first.
8. **Per-platform implementation behind one interface.** The `kernel` role's inputs are the same everywhere; `vars/family-RedHat.yml`, `family-Debian.yml` and `family-Suse.yml` supply the mechanism, and an unsupported platform fails on the first task with a message naming it. This is the rule [`docs/platform-translation.md`](../../../docs/platform-translation.md) gives for a second cloud, applied to a second distribution.

## Why `patch` is thin

It would be easy to put `serial`, the health gate and the abort threshold inside the patch role. They belong to the **play**, because they describe the fleet and the change window, not how to patch a host. The same role can then be used by a scheduled patch run (batches of 25%), an emergency CVE run (batches of 5, human watching) and a rebuild pipeline (one host, no drain), each with its own play.
