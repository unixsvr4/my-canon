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

Folding these into one hierarchy (`prod-web-saturday`) multiplies groups and makes every new host a naming exercise.
Independent axes compose instead: `--limit 'web:&window_sat_2200'`.

## Variable layering

Lowest to highest precedence, as used here:

1. **role defaults** (`roles/*/defaults/main.yml`) — safe values
2. **`group_vars/all.yml`** — fleet-wide
3. **`group_vars/<tier>.yml`** — per tier, using `_extra` variables to *add* to role defaults instead of replacing them
4. **`host_vars/<host>.yml`** — genuine one-offs only

Every `host_var` is a permanent difference between servers that are supposed to be identical, so this repository has
exactly one, and it is labelled as deliberate.

```bash
ansible-inventory --graph
```

```bash
ansible-inventory --host db01 --yaml
```

## In production

A static list is itself a drift surface: a server that exists but isn't listed is never patched and never checked.
Production uses a dynamic inventory plugin (vCenter, the CMDB, or `aws_ec2` keyed on tags), with `keyed_groups`
producing the same three axes from tags such as `role`, `patch_window` and `os`.
