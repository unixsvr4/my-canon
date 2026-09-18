# inventory/

```text
inventory/
├── hosts.yml            # WHAT exists and how it is grouped - no variables
├── group_vars/
│   ├── all.yml          # connection (lab), fleet-wide role inputs
│   ├── web.yml          # web tier: extra sysctl, health check
│   ├── db.yml           # db tier: extra sysctl + package, no LB drain
│   └── app.yml          # app tier: role defaults unchanged
└── host_vars/
    └── web03.yml        # the one deliberate one-off: a failing health gate
```

## Three grouping axes

A rollout needs three independent answers about each host, so hosts belong to three independent sets of groups:

| Axis | Groups | Decides |
|---|---|---|
| What is it? | `linux`, `rhel9` | which roles and OS defaults apply |
| What does it run? | `web`, `db`, `app` | tuning, drain behaviour, which health check proves it's back |
| When can it be touched? | `canary`, `window_sat_2200`, `window_sun_0200`, `never_unattended` | batching and maintenance windows |

Folding these into one hierarchy (`prod-web-saturday`) multiplies groups and makes every new host a naming exercise. Independent axes compose instead: `--limit 'web:&window_sat_2200'`.

## Variable layering

Lowest to highest precedence, as used here:

1. **role defaults** (`roles/*/defaults/main.yml`) — safe values
2. **`group_vars/all.yml`** — fleet-wide
3. **`group_vars/<tier>.yml`** — per tier, using `_extra` variables to *add* to role defaults instead of replacing them
4. **`host_vars/<host>.yml`** — genuine one-offs only

Every `host_var` is a permanent difference between servers that are supposed to be identical, so this repository has exactly one, and it is labelled as deliberate.

```bash
ansible-inventory --graph
```

```bash
ansible-inventory --host db01 --yaml
```

## In production

A static list is itself a drift surface: a server that exists but isn't listed is never patched and never checked. Production uses a dynamic inventory plugin (vCenter, the CMDB, or `aws_ec2` keyed on tags), with `keyed_groups` producing the same three axes from tags such as `role`, `patch_window` and `os`.

## The other two inventories

| File | For | Notes |
|---|---|---|
| [`kernel-hosts.yml`](kernel-hosts.yml) | the four distribution containers used by `kernel.yml` | each host gets a **different** `kernel_profile`, which is the honest test of a reusable role. Two variables are set for the whole group because a container cannot own a kernel — `kernel_sysctl_apply: false` (no writing `/proc/sys`) and `kernel_sysctl_strict: false` (inside a container, `/proc/sys` is the *host's* key set, so the check would be testing the wrong machine). Both go back to their defaults on a real host. |
| [`aws_ec2.yml`](aws_ec2.yml) | **production**: EC2, grouped by the tags Terraform stamps | replaces this directory's static list entirely. A hand-maintained host list is itself a drift surface: a server that exists and is not in the file is never patched, never checked, and never in a drift report. Needs credentials to return hosts, so `make lab2-static` checks only that the plugin is installed and the config parses. |

`group_vars/aws_ec2.yml` is the connection half: Session Manager instead of SSH (no inbound rule, no bastion, no key), and Secrets Manager lookups instead of Ansible Vault. The group name matches the plugin name, so it applies to discovered instances and to nothing else — the containers keep their own settings in `all.yml`.

One thing worth knowing about the dynamic inventory: without credentials it returns an **empty group rather than an error**. So "no hosts matched" is what a missing identity looks like, and `strict: true` plus `unparsed_is_failed` in `ansible.cfg` catch a broken *config* but not a missing *identity*.
