# Idempotence: six anti-patterns and their fixes

| File | Purpose |
|---|---|
| `not-idempotent.yml` | six tasks that each "work" on the first run |
| `idempotent.yml` | the same six outcomes, written to converge |
| `reset.yml` | removes everything both create, so they can be compared from a clean host |

## Run

```bash
ansible-playbook examples/idempotence/reset.yml && tests/idempotence.sh examples/idempotence/not-idempotent.yml
```

```text
== run 2: must change nothing
   FAIL  app01  changed=6
           - 1 | Append a kernel parameter with echo
           - 2 | Create a user with useradd
           - 3 | Write a config file stamped with the deploy time
           - 4 | Set the log level with sed
           - 5 | Restart the app every run
           - 6 | Create a virtualenv
NOT IDEMPOTENT: 1 of 1 host(s) changed on a second run.
```

And the host is now slightly corrupted:

```bash
docker exec lab-app01 cat /etc/sysctl.d/99-demo.conf
```

```text
net.core.somaxconn = 1024
net.core.somaxconn = 1024
```

```bash
ansible-playbook examples/idempotence/reset.yml && tests/idempotence.sh examples/idempotence/idempotent.yml
```

```text
   PASS  app01  changed=0
IDEMPOTENT: 1 host(s), zero changes on the second run.
```

## The six pairs

| # | Anti-pattern | Why it fails | Fix |
|---|---|---|---|
| 1 | `shell: echo "key = value" >> file` | appends a copy every run; the file grows forever | `lineinfile` with an anchored `regexp`, or template the whole file |
| 2 | `command: useradd demo-svc` with `failed_when: rc not in [0, 9]` | exits 9 on run 2; the workaround hides real failures and reports changed forever | `ansible.builtin.user` |
| 3 | `copy` content containing `{{ now() }}` | content differs every run, so the file is rewritten and drift can never be clean | no per-run values in managed content; deploy metadata goes in logs or labels |
| 4 | `shell: sed -i 's/^log_level.*/.../' file` | the command can't tell whether sed changed anything; a pattern that stops matching fails silently | one task owns the file (template/copy), or `lineinfile`/`replace` |
| 5 | `command: systemctl restart app` as a task | restarts on every run, including runs where nothing changed | a **handler**, notified only by the task that changed the config |
| 6 | `command: python3 -m venv --clear ...` | rebuilds the environment every run | `args: creates: /opt/demo-app/venv/bin/python3` |

## Linting is not enough

With the `production` profile, ansible-lint flags **five** of the six tasks, run against a copy outside this repo's exclude list:

```text
line 18: no-changed-when            # 1  echo >>
line 24: no-changed-when            # 2  useradd
line 42: command-instead-of-module  # 4  sed
line 42: no-changed-when            # 4
line 47: no-changed-when            # 5  restart every run
line 51: no-changed-when            # 6  venv
```

Two things stand out:

- **Task 3 isn't flagged at all.** A timestamp inside `copy` content is perfectly valid syntax. Only running the play twice reveals it.
- **Most findings are `no-changed-when`, and the easy way to silence that rule is wrong.** Adding `changed_when: false` to the `echo >>` task makes the linter pass while the file keeps growing. The rule points at a symptom; the idempotence test measures the behaviour.

So lint on every commit, and also run a converge-twice test (this script, or Molecule's `idempotence` step) on every role change.
