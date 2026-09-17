# tests/

Behavioural tests for the roles. Both run against the lab containers (`./setup.sh` first), from `labs/lab2-ansible/`.

| Script | Proves | Pass condition |
|---|---|---|
| [`idempotence.sh`](idempotence.sh) | a playbook converges and then changes nothing | run 2 reports `changed=0` on every host |
| [`input-validation.sh`](input-validation.sh) | bad inputs are rejected before any task touches a host | 8 of 8 invalid inputs fail with the expected message |

```bash
tests/idempotence.sh
```

```bash
tests/idempotence.sh examples/idempotence/not-idempotent.yml   # expected: exit 1, six tasks listed
```

```bash
tests/input-validation.sh
```

## How `idempotence.sh` works

1. Runs the playbook once (converge). If that fails, it prints the failing tasks and exits **2**.
2. Runs it again with the `ansible.posix.json` stdout callback.
3. Parses the JSON (it doesn't grep text) and lists every task that reported `changed` on each host. Exits **1** if any
   did, **0** otherwise.

Two details needed for the JSON to parse, both found the hard way:

- `profile_tasks` (enabled in `ansible.cfg`) prints timing lines into the same stdout, so the script sets
  `ANSIBLE_CALLBACKS_ENABLED=ansible.posix.json`. Setting it to an empty string crashes ansible-core 2.21 with
  *"A non-empty plugin name is required"*.
- When a host fails, ansible prints the retry-file hint above the JSON, so retry files are disabled for these runs.

This is the idempotence step of `molecule test`, reduced to plain `ansible-playbook` so it runs anywhere.

## How `input-validation.sh` works

Each case runs `site.yml --check --limit web01 -e '<bad input>'` and requires a non-zero exit **and** a specific
message. Check mode against one host means even a guard that failed to fire would change nothing.

| Layer | Cases |
|---|---|
| `meta/argument_specs.yml` | choice outside the allowed set; wrong type; nested `state` choice; missing required `name` |
| `tasks/validate.yml` | duplicate user names; `_extra` redefining a role-owned sysctl; root login open with passwords; **a bare YAML boolean for `PermitRootLogin`** |

The last case sits in the second layer because the first layer misses it. For a `str` option whose choices include
`"no"`/`"yes"`, ansible-core's choice check accepts a YAML boolean, so an unquoted `no` passes the spec and would render
`PermitRootLogin False`. `validate.yml` asserts `is string` explicitly. (Verified on ansible-core 2.21.4.)
