# Lab 1 — Terraform: modules, `for_each`, tests, drift and recovery

Runs entirely on your machine with the `local`, `random` and built-in `terraform_data` providers. **No cloud
account, no credentials, $0.** Each resource is a small file standing in for a cloud resource (the mapping is at the
top of [`modules/app_stack/main.tf`](modules/app_stack/main.tf)), so you get the real Terraform workflow — module
design, environment roots, `for_each` addressing, native tests, drift detection, and state recovery — without
paying for it.

## What this lab demonstrates

| Capability | Where | How to see it |
|---|---|---|
| Reusable module with a typed, validated input contract | `modules/app_stack/variables.tf` | Exercise D |
| `for_each` over maps, flattened nested maps, filtered maps, and other resources | `modules/app_stack/main.tf` | Exercise B |
| Thin per-environment roots, directory-per-env (not workspaces) | `envs/dev`, `envs/prod` | Exercise A |
| Native `terraform test` suite, with guard-rail tests proven by mutation | `modules/app_stack/tests/` | Exercise C |
| Saved-plan workflow: apply exactly what was reviewed | — | Exercise A |
| Drift detection with an immutable record that survives remediation | `drift-check.sh`, `drift-show.py` | Exercise E |
| State recovery: out-of-band deletion, `import` blocks, `-replace` | — | Exercise F |
| `count` vs `for_each`, nested keys, and `moved`-block migrations | `examples/` | Exercise G |

## Layout

```text
lab1-terraform/
├── modules/
│   └── app_stack/            # the reusable module: all logic lives here
│       ├── versions.tf       #   provider CONSTRAINTS only - never a provider block
│       ├── variables.tf      #   typed inputs, optional() defaults, validations
│       ├── main.tf           #   a guided tour of for_each patterns A-E
│       ├── outputs.tf        #   the public interface, shaped as maps
│       └── tests/            #   terraform test: keys, filters, guard rails
├── envs/
│   ├── dev/                  # thin root: backend + inputs, no resource logic
│   └── prod/                 # same module, stricter inputs
├── examples/                 # four standalone, self-cleaning for_each demos
├── drift-check.sh            # plan -detailed-exitcode + immutable drift record
└── drift-show.py             # read the drift archive without raw JSON
```

Every directory has its own README explaining its piece in more depth.

## Prerequisites

Terraform ≥ 1.6 (verified on 1.16.1), `jq`, Python 3. From the repository root, `make lab1-test` runs the
module tests and `make tf-examples` runs all four examples.

> **Shell note.** If `TF_WORKSPACE` is set in your environment, Terraform stores local state under
> `terraform.tfstate.d/<workspace>/` instead of `terraform.tfstate`. Everything still works; it is just where the
> state file ends up. (This lab deliberately uses directories, not workspaces, to separate environments.)

---

**Every exercise starts from `labs/lab1-terraform/`** — each command block `cd`s relative to it.

## Exercise A — plan, review, apply the saved plan

```bash
cd envs/dev && terraform init && terraform plan -out=tfplan
```

```bash
terraform apply tfplan && terraform output
```

You applied a **saved plan file**, not a fresh plan. That is the production pattern: the pull request shows a
specific diff, a human approves that diff, and CI applies exactly that file. Re-planning at apply time can pick up
changes nobody reviewed.

Now plan prod — same module, different inputs:

```bash
cd ../prod && terraform init && terraform plan
```

dev plans 9 resources and prod plans 15. The difference is data, not code: prod has three services, two of them
public with ports, and every extra resource comes from `for_each` expanding that input — 3 deploy ids, 3 services,
3 listeners (`api-443`, `api-8443`, `web-443`), 2 public endpoints, 3 runbooks, and the one datastore.

## Exercise B — the `for_each` tour

```bash
cd envs/dev && terraform state list
```

```text
module.app_stack.local_file.listener["api-8080"]      <- B. flattened service x port, composite key
module.app_stack.local_file.runbook["api"]            <- D. for_each over another resource
module.app_stack.local_file.service["api"]            <- A. for_each over a map of objects
module.app_stack.local_file.stateful_store            <- E. deliberately NOT for_each
module.app_stack.random_id.deploy["api"]              <- keyed like its consumers (see below)
...
```

Every address contains a **name**, not a position. Prove it matters — remove `web` without editing any file:

```bash
terraform plan -var 'services={api={image="api:1.4.2",cpu=256,memory=512,ports=[8080]}}'
```

Exactly `web`'s four resources are destroyed: its service, listener, runbook and deploy id. `api` is untouched. Now
bump only `api`'s image:

```bash
terraform plan -var 'services={api={image="api:1.5.0",cpu=256,memory=512,ports=[8080]},web={image="web:2.1.0",cpu=256,memory=512,ports=[8080]}}'
```

Only `api`'s resources change.

> **A bug this lab caught, and why it is instructive.** The first version of the module had *one* `random_id` for
> the whole stack, with `keepers` set to the list of service names, and every service embedded it. Removing `web`
> changed that one id — and **replaced `api` too**. `for_each` had isolated the services; a single shared dependency
> silently coupled them again. The fix was to key the dependency exactly like its consumers
> (`random_id.deploy[each.key]`), and a regression test now guards it. When a plan touches keys you didn't change,
> look for a shared upstream value.

## Exercise C — native tests

```bash
cd modules/app_stack && terraform init && terraform test
```

12 runs, all `command = plan` — nothing is created, so it is fast enough for every pull request. Half the suite
asserts what `for_each` produces (keys, composite keys, filters, zero-instance cases). The other half uses
`expect_failures` to prove the guard rails **reject** bad input.

A test that expects a failure is only worth something if it would fail without the guard. Both kinds were checked
by mutation: deleting the prod replica precondition, or the `:latest` tag validation, makes the corresponding test
fail (see `RESEARCH.md`).

## Exercise D — guard rails fail in plan, not in apply

```bash
cd envs/prod && terraform plan -var 'services={api={image="api:1.4.2",cpu=512,memory=1024,desired_count=1}}'
```

```text
Error: Resource precondition failed
  Service api: prod requires desired_count >= 2 so one instance can fail.
```

```bash
terraform plan -var 'services={api={image="api:latest",cpu=512,memory=1024,desired_count=2}}'
```

```text
Error: Invalid value for variable
  every service image needs an explicit, immutable tag (name:1.2.3), never :latest or untagged.
```

The reviewer sees a readable error in the pull request, rather than an API error twenty minutes into an apply that
has already changed half an environment.

## Exercise E — drift detection with a record that outlives the fix

Simulate an out-of-band change, then check:

```bash
echo '{"tampered":true}' > envs/dev/.artifacts/canon-dev-api.json && ./drift-check.sh envs/dev; echo "exit=$?"
```

`terraform plan -detailed-exitcode` returns **0** (no changes), **1** (error) or **2** (drift). The script turns exit 2
into a permanent record:

```text
[DRIFT] envs/dev: infrastructure does not match code
[ARCHIVED] 1 drifted resource(s) -> drift-history/envs-dev/20260917T123706Z
```

Remediate by re-applying the code, then check again. The environment is clean, and the record is still there:

```bash
(cd envs/dev && terraform apply -auto-approve) && ./drift-check.sh envs/dev; ./drift-show.py
```

```bash
./drift-show.py latest
```

Why it is built this way:

- **The record survives remediation.** "What changed, when did we notice, how long was it that way" can only be
  answered if applying the fix doesn't also erase the evidence. Each record is `plan.txt` (for a human or a ticket)
  plus `plan.json` (for a policy engine such as OPA/conftest), made read-only on write, with a row in
  `drift-history/index.csv`.
- **The binary plan is not kept by default.** A `.tfplan` is valid only against the state serial that produced it,
  and it holds every attribute in the clear, secrets included. `KEEP_PLAN=1` retains it on purpose; otherwise it
  is deleted.
- **Tampering showed up as `+ create`, not an update.** `local_file`'s ID is the SHA-1 of its content, so refresh
  concluded the resource was gone — the same shape as a cloud resource someone deleted by hand.

## Exercise F — recovering state

**Something exists in reality but not in state** (a partial apply, a lost state write):

```bash
cd envs/dev && terraform state rm 'module.app_stack.local_file.service["api"]' && terraform plan
```

Terraform now plans to *create* `api` again. On a real provider that duplicate would collide on its name, so the fix
is to **adopt** the existing object. Declaratively, since Terraform 1.5, in the root:

```hcl
import {
  to = module.app_stack.aws_ecs_service.service["api"]
  id = "canon-cluster/canon-dev-api"
}
```

An `import` block is reviewed in the PR and shows up in `plan` like any other change, which is why it beats running
`terraform import` by hand. (The `local` provider doesn't implement import, so here you simply re-apply.)

**Something exists but can't be trusted** (half-configured, hand-edited):

```bash
terraform apply -replace='module.app_stack.local_file.service["api"]' -auto-approve
```

`-replace` destroys and recreates exactly one address; it is the modern spelling of `taint`.

**Before approving any prod plan**, look for replacements explicitly:

```bash
terraform plan -no-color | grep -E 'must be replaced|forces replacement' || echo "no replacements"
```

A replacement in prod should be its own deliberate change, never a side effect of something else.

## Exercise G — the `for_each` examples

Four self-contained roots, each with a `demo.sh` that runs the scenario, prints a one-line-per-resource plan
summary, and cleans up after itself. Details in [`examples/README.md`](examples/README.md).

```bash
./examples/01-count-vs-for-each/demo.sh
```

```bash
./examples/02-for-each-shapes/demo.sh
```

```bash
./examples/03-nested-for-each/demo.sh
```

```bash
./examples/04-count-to-for-each-moved/demo.sh
```

## Production mapping

| In this lab | In production |
|---|---|
| `local_file`, `terraform_data` | ECS services, listeners, Route 53 records, security-group rules |
| local state | S3 backend, one key per root, SSE-KMS, versioning on, state bucket in a separate account, `use_lockfile = true` (S3-native locking, Terraform 1.10+) |
| `source = "../../modules/app_stack"` | a pinned git tag or registry version; promotion = bumping the ref in `envs/prod` |
| running `plan` by hand | PR pipeline: `fmt -check`, `validate`, `tflint`, `terraform test`, policy on plan JSON, plan posted to the PR; apply of the saved plan on merge |
| `drift-check.sh` | a scheduled job per root (or Spacelift drift detection) that opens a ticket linking the record |
| a stuck lock | `terraform force-unlock <id>` — only after confirming the lock's owner is really gone |

## Cleanup

```bash
(cd envs/dev && terraform destroy -auto-approve); (cd envs/prod && terraform destroy -auto-approve); rm -rf drift-history
```
