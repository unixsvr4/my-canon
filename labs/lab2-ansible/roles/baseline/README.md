# Role: `baseline`

Converges a RHEL-family host to the platform baseline: packages, admin access, sshd hardening, time sync, kernel parameters and the login banner. Then it **verifies the effective configuration**, not just the files it wrote.

Designed to be **reused unchanged** across host types, environments and platforms (containers, VMs, bare metal), and to be **idempotent**: a second run reports zero changes, which `tests/idempotence.sh` proves on every host.

```yaml
- name: Converge Linux hosts to the platform baseline
  hosts: linux
  roles:
    - role: baseline
```

## Layout

```text
baseline/
├── defaults/main.yml         # every input, with its SAFE default and an explanation
├── meta/
│   ├── argument_specs.yml    # the input contract: types, choices, required keys - enforced before any task
│   └── main.yml              # galaxy metadata, platforms, no dependencies
├── tasks/
│   ├── main.yml              # order + tags; imports each section below
│   ├── validate.yml          # rules spanning several variables (the spec can't express these)
│   ├── packages.yml          # state: present, never latest
│   ├── access.yml            # group, users, keys, validated sudoers
│   ├── ssh.yml               # host keys via creates:, validated drop-in, reload via handler
│   ├── time.yml              # chrony
│   ├── sysctl.yml            # one templated file owns every key
│   ├── motd.yml              # no per-run values
│   └── verify.yml            # sshd -T and visudo -c: the EFFECTIVE configuration
├── handlers/main.yml         # reloads, only on change, skipped cleanly without systemd
└── templates/                # sshd drop-in, sudoers, chrony.conf, sysctl, motd
```

## Variables

All variables are prefixed `baseline_`. Full types and choices are in [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Notes |
|---|---|---|
| `baseline_packages` | `openssh-server, chrony, sudo, procps-ng` | role-owned list |
| `baseline_packages_extra` | `[]` | caller-owned, appended |
| `baseline_admin_group` | `ops` | allowed in sshd and granted sudo |
| `baseline_admin_users` | `[]` | `{name, key?, state?: present\|absent}` |
| `baseline_admin_sudo_nopasswd` | `false` | |
| `baseline_ssh_permit_root_login` | `"no"` | `"no"` \| `"prohibit-password"` \| `"yes"` — **quote it** |
| `baseline_ssh_password_authentication` | `false` | |
| `baseline_ssh_max_auth_tries` | `3` | |
| `baseline_ssh_client_alive_interval` | `300` | seconds |
| `baseline_ssh_dropin` | `/etc/ssh/sshd_config.d/10-baseline.conf` | must sort before vendor drop-ins |
| `baseline_ntp_servers` | `0/1.pool.ntp.org` | |
| `baseline_sysctl` | syncookies, no redirects, `dmesg_restrict`, `swappiness=10` | role-owned dict |
| `baseline_sysctl_extra` | `{}` | caller-owned, merged; may not redefine role-owned keys |
| `baseline_sysctl_apply` | `true` | `false` where the kernel isn't the host's (containers) |
| `baseline_motd_owner` / `_contact` | Platform Engineering / `platform@canon.example` | |
| `baseline_verify` | `true` | assert effective sshd + sudo config after converging |

## Tags

`baseline` (everything) · `baseline_validate` · `baseline_packages` · `baseline_access` · `baseline_ssh` · `baseline_time` · `baseline_sysctl` · `baseline_motd` · `baseline_verify`

```bash
ansible-playbook site.yml --tags baseline_ssh --limit web01
```

Sections are pulled in with `import_tasks` (static), so tags on the import apply to every task inside. With `include_tasks` (dynamic), `--tags baseline_ssh` would skip the include and none of the SSH tasks would run.

---

## Reusability

What makes one role serve web, db and app hosts, dev and prod, containers and bare metal, **without a single conditional on host type**:

### 1. All behaviour is driven by prefixed variables with safe defaults

The role never checks `if 'db' in group_names`. Differences between host types live in inventory as data (`inventory/group_vars/db.yml`), so adding a new tier needs no change to the role.

### 2. The `_extra` merge pattern

Ansible **replaces** dictionaries and lists at higher precedence; it doesn't merge them. If `group_vars/db.yml` set `baseline_sysctl`, db hosts would silently lose every default kernel parameter. So each collection comes in two parts:

```yaml
# role default (role-owned)            # group_vars/db.yml (caller-owned)
baseline_sysctl:                       baseline_sysctl_extra:
  net.ipv4.tcp_syncookies: 1             vm.dirty_ratio: 10
  vm.swappiness: 10
```

```jinja
{% for key, value in (baseline_sysctl | combine(baseline_sysctl_extra)) | dictsort %}
```

`tasks/validate.yml` refuses an `_extra` key that redefines a role-owned key. Overriding a default should be a visible decision (set `baseline_sysctl`), never a side effect.

### 3. The input contract is enforced, not documented

`meta/argument_specs.yml` is checked by ansible-core before the first task. A typo or wrong type fails immediately, with a message, instead of rendering a broken config across a fleet. `tests/input-validation.sh` exercises 8 bad inputs.

### 4. It runs where its assumptions don't hold

- Minimal images have no `/etc/sysctl.d` and no `sysctl` binary, so the role creates the directory and installs `procps-ng`.
- Containers have no systemd, so handlers check `ansible_facts['service_mgr']` and skip reloads instead of failing.
- Containers share the host kernel, so `baseline_sysctl_apply: false` still manages the file (and detects drift) but doesn't load it.

### 5. No dependencies, handler names namespaced

`meta/main.yml` declares `dependencies: []`, so composition happens in playbooks where it is visible. Handlers are named `Baseline | reload sshd`, so combining roles in one play can't trigger another role's handler by accident.

---

## Idempotence

**Idempotent means a second run against a correct host changes nothing.** That isn't cosmetic. A play that always reports `changed` restarts services for no reason, and it can't tell a correct host from a drifted one, so its drift report is noise.

The techniques the role uses, and where:

| Technique | Where | Instead of |
|---|---|---|
| **Declarative modules** compare desired and actual state | `package`, `group`, `user`, `authorized_key` | `command: useradd` (fails on run 2), `command: dnf install` (always "changed") |
| **`state: present`, never `latest`** | `packages.yml` | `latest`, which converges to a different result on different days |
| **Template the whole file** so one owner defines all of it | sshd drop-in, sudoers, chrony, sysctl, motd | `sed -i` / `echo >>` edits of files others also edit |
| **`creates:`** makes a command a no-op once its result exists | `ssh-keygen -A` | an unguarded command |
| **Handlers** restart only when notified, once per play | `handlers/main.yml` | `service: state=restarted` as a task |
| **Stable rendering**: `dictsort`, no timestamps or run ids | `sysctl-baseline.conf.j2`, `motd.j2` | iterating dicts in varying order; "last updated" lines |
| **`changed_when: false`** on read-only commands | `verify.yml` | commands that report changed while only reading |
| **One file owns a whole set** so removing an input removes the line | `sysctl.yml` | `ansible.posix.sysctl` per key, which leaves removed keys behind forever |

And the safety techniques that go with them:

| Technique | Where | Why |
|---|---|---|
| `validate: /usr/sbin/sshd -t -f %s` | `ssh.yml` | a broken sshd config is never installed |
| `validate: /usr/sbin/visudo -cf %s` | `access.yml` | a broken sudoers rule can't lock out the people who'd fix it |
| `meta: flush_handlers` before verify | `main.yml` | verification sees the reloaded service, not the old one |
| `sshd -T` assertions | `verify.yml` | a correct file can still be overridden (next section) |

Proven, not asserted:

```bash
tests/idempotence.sh            # converge, then run 2 must report changed=0 on every host
```

### Why the role verifies the *effective* configuration

The AlmaLinux 9 image ships `/etc/ssh/sshd_config.d/25-permitrootlogin.conf` with `PermitRootLogin yes`. sshd reads drop-ins in lexical order, and **the first value wins**. A hardening drop-in named `50-` or `99-` is written correctly, every task reports success, and `sshd -T` still shows `permitrootlogin yes`.

The role handles this in two ways. The drop-in is named `10-baseline.conf`, and `verify.yml` asserts on `sshd -T` output, so any future file that sorts earlier fails the run loudly. Lab 2 README, Step 5, reproduces it.

Verification is **skipped in check mode**. Nothing was converged, so on a drifted host the effective config is still the drifted one; failing there would turn a drift finding into an "incomplete run".

## Known limits

- RHEL-family only (`package` + dnf, `/etc/chrony.conf` path, `procps-ng`). Debian support would add per-OS vars files loaded with `include_vars` on `ansible_facts['os_family']`.
- Removing an admin user needs `state: absent` for at least one run before the entry is deleted from inventory. Ansible manages only what it is told about.
