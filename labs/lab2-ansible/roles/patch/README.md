# Role: `patch`

Patches **one host**, safely, in a strict order. Fleet-level decisions (batch size, health gates, what aborts the run)
live in the calling play, [`../../patch.yml`](../../patch.yml).

```text
tasks/main.yml
├── preflight.yml   assert BEFORE touching anything
├── patch.yml       apply updates (simulated in the lab; dnf --security in production)
└── reboot.yml      reboot only if required, then confirm the new kernel
```

## Pre-flight assertions

Each assertion guards against a real failure mode.

| Assertion | The failure it prevents |
|---|---|
| `/var` has at least `patch_min_free_var_mb` free | a transaction that fills `/var` halfway through and wedges the RPM database |
| no `/var/run/dnf.pid` | two package transactions fighting over the same lock |
| `ansible_facts['hostname'] == inventory_hostname` | patching the wrong machine because a DNS record or inventory entry is stale |
| a recent snapshot or backup exists (simulated) | no rollback path; no restore point means no patch |

## Update

- **Lab** (`patch_simulate: true`): a simulated transaction guarded by `creates:`, so it is idempotent too.
- **Production** (`patch_simulate: false`): `dnf name="*" state=latest security=true` against a repository **pinned to a
  snapshot for the whole patch cycle**, so host 1 and host 200 receive an identical package set. Patching against a
  live upstream mirror produces drift between hosts patched an hour apart.

`state: latest` is the one place in this repository where ansible-lint's `package-latest` rule is waived. Upgrading is
the purpose of this role, and the `baseline` role uses `present` for exactly the opposite reason.

## Reboot

Only if `/var/run/reboot-required` exists. After a real reboot the role should confirm that the **running** kernel
is the newest installed one. A host that boots the old kernel because the bootloader entry didn't update looks
healthy and isn't patched.

## Inputs

| Variable | Default | Meaning |
|---|---|---|
| `patch_simulate` | `true` | lab mode; `false` runs dnf for real |
| `patch_security_only` | `true` | security errata only |
| `patch_min_free_var_mb` | `512` | pre-flight free-space floor |
| `patch_health_retries` | `3` | used by the play's health gate |
| `patch_health_delay` | `2` | seconds between health-gate attempts |

Contract: [`meta/argument_specs.yml`](meta/argument_specs.yml). Facts it sets for the play's per-host record:
`patch_kernel_before`, `patch_started_at`, `patch_packages`, `patch_changed`, `patch_rebooted`.
