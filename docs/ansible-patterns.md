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
