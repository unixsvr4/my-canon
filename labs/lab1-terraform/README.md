# Lab 1 — Terraform: modules, `for_each`, tests, drift and recovery

Runs entirely on your machine with the `local`, `random` and built-in `terraform_data` providers. **No cloud account, no credentials, $0.** Each resource is a small file standing in for a cloud resource (the mapping is at the top of [`modules/app_stack/main.tf`](modules/app_stack/main.tf)), so you get the real Terraform workflow — module design, environment roots, `for_each` addressing, native tests, drift detection, and state recovery — without paying for it.

## What this lab demonstrates

| Capability | Where | How to see it |
|---|---|---|
| Reusable module with a typed, validated input contract | `modules/app_stack/variables.tf` | Exercise E |
| `for_each` over maps, flattened nested maps, filtered maps, and other resources | `modules/app_stack/main.tf` | Exercise C |
| Thin per-environment roots, directory-per-env (not workspaces) | `envs/dev`, `envs/prod` | Exercise A |
| Saved-plan workflow: apply exactly what was reviewed, in dev and prod | `envs/dev`, `envs/prod` | Exercise A |
| **Post-apply verification** of the live environment, proven by tampering with it | `verify-env.py`, `tamper-env.sh` | Exercise B |
| Native `terraform test`: plan-time unit tests **and** apply-time integration tests, all mutation-checked | `modules/app_stack/tests/` | Exercise D |
| Drift detection with an immutable record that survives remediation | `drift-check.sh`, `drift-show.py` | Exercise F |
| State recovery: out-of-band deletion, `import` blocks, `-replace` | — | Exercise G |
| `count` vs `for_each`, nested keys, and `moved`-block migrations | `examples/` | Exercise H |
| **The same module on real AWS**, apply-tested with `mock_provider` at no cost | [`aws/`](aws/) | [`aws/README.md`](aws/README.md) |

The resources in this directory are `local_file` stand-ins, so the lab is free and offline. [**`aws/`**](aws/) is the same module against the real `aws` provider — ECS Fargate, ALB, RDS, IAM, KMS — with 22 `terraform test` runs against a mocked provider, so real cloud infrastructure is apply-tested on every commit with no account and no bill. Read the two side by side: the `for_each` patterns are identical, and every stand-in maps to the resource it models.

## Layout

```text
lab1-terraform/
├── modules/
│   └── app_stack/            # the reusable module: all logic lives here
│       ├── versions.tf       #   provider CONSTRAINTS only - never a provider block
│       ├── variables.tf      #   typed inputs, optional() defaults, validations
│       ├── main.tf           #   a guided tour of for_each patterns A-E
│       ├── outputs.tf        #   the public interface, shaped as maps
│       └── tests/            #   terraform test: plan-time unit + apply-time integration
├── envs/
│   ├── dev/                  # thin root: backend + inputs, no resource logic
│   └── prod/                 # same module, stricter inputs
├── examples/                 # four standalone, self-cleaning for_each demos
├── verify-env.py             # post-apply verification: test what was BUILT, not the code
├── tamper-env.sh             # out-of-band changes for verify-env.py to catch
├── drift-check.sh            # plan -detailed-exitcode + immutable drift record
└── drift-show.py             # read the drift archive without raw JSON
```

Every directory has its own README explaining its piece in more depth.

## Prerequisites

Terraform ≥ 1.6 (verified on 1.16.1), `jq`, Python 3. From the repository root, `make lab1-test` runs the module tests, `make tf-examples` runs all four examples, and `make lab1-e2e` runs the whole lifecycle below — apply both environments, verify them, tamper, remediate, destroy, and prove nothing was left behind — in under ten seconds.

> **Shell note.** If `TF_WORKSPACE` is set in your environment, Terraform stores local state under `terraform.tfstate.d/<workspace>/` instead of `terraform.tfstate`. With `TF_WORKSPACE=dev`, prod's state lands in `envs/prod/terraform.tfstate.d/dev/` — the `dev` there is the workspace name, not the environment. Everything still works. (This lab deliberately uses directories, not workspaces, to separate environments.)

---

**Every exercise starts from `labs/lab1-terraform/`** — each command block `cd`s relative to it.

## Exercise A — plan, review, apply the saved plan (dev, then prod)

```bash
cd envs/dev && terraform init && terraform plan -out=tfplan
```

```bash
terraform apply tfplan && terraform output
```

You applied a **saved plan file**, not a fresh plan. That is the production pattern: the pull request shows a specific diff, a human approves that diff, and CI applies exactly that file. Re-planning at apply time can pick up changes nobody reviewed.

Now prod — same module, different inputs, same workflow:

```bash
cd ../prod && terraform init && terraform plan -out=tfplan
```

```bash
terraform apply tfplan && terraform output
```

dev creates 9 resources and prod creates 15. The difference is data, not code: prod has three services, two of them public with ports, and every extra resource comes from `for_each` expanding that input — 3 deploy ids, 3 services, 3 listeners (`api-443`, `api-8443`, `web-443`), 2 public endpoints, 3 runbooks, and the one datastore.

`Apply complete!` means the provider accepted every call. It doesn't mean either environment is right. That's the next exercise.

## Exercise B — verify what you built

```bash
./verify-env.py envs/dev && ./verify-env.py envs/prod
```

```text
== verify envs/prod (after apply)
   PASS  exists     12 managed object(s) present, 3 deploy id(s) in state
   PASS  integrity  every object matches what Terraform last wrote
   PASS  unmanaged  no objects outside Terraform's control
   PASS  wiring     3 listener(s), 2 endpoint(s) and 3 runbook(s) resolve
   PASS  policy     tags, TLS, image tags, replicas and deletion protection OK (prod)
   PASS  outputs    outputs match the real objects
[VERIFIED] 6 of 6 checks passed
```

The module tests (Exercise D) prove the **code** is right. `verify-env.py` tests the **environment**: it reads state and outputs, then inspects every real object, so it also catches things that happened after — or outside of — the apply.

| Check | Question | The AWS equivalent |
|---|---|---|
| `exists` | does every resource in state have a real object? | `aws ecs describe-services`, `aws elbv2 describe-listeners` |
| `integrity` | does each object still match what Terraform wrote (content *and* permissions)? | compare live attributes to `terraform show -json` |
| `unmanaged` | does anything exist that Terraform doesn't know about? | tag inventory via `aws resourcegroupstaggingapi` vs state |
| `wiring` | do references resolve — listener → service, endpoint → listeners, runbook → definition, deploy ids? | target-group health; a request through each endpoint |
| `policy` | do the **built** objects meet policy — tags, TLS on public listeners, prod replicas ≥ 2, deletion protection? | AWS Config rules / Security Hub |
| `outputs` | does what the root publishes to its consumers match reality? | the next stack's data sources |

A verifier that has never failed proves nothing. Tamper with prod the way people do — hand-scale a service, create a "temporary" object, loosen a permission:

```bash
./tamper-env.sh envs/prod && ./verify-env.py envs/prod; echo "exit=$?"
```

```text
   FAIL  integrity  content differs from state: .artifacts/canon-prod-api.json
                    permission 0666, expected 0644: .artifacts/canon-prod-datastore.json
   FAIL  unmanaged  not in state: .artifacts/canon-prod-hotfix.json
   FAIL  policy     service api: desired_count 1 in prod (minimum 2)
[FAIL] 3 of 6 check(s) failed: integrity, unmanaged, policy
exit=1
```

Remediate the usual way, by re-applying the code:

```bash
(cd envs/prod && terraform apply -auto-approve) && ./verify-env.py envs/prod; echo "exit=$?"
```

```text
   FAIL  integrity  permission 0666, expected 0644: .artifacts/canon-prod-datastore.json
   FAIL  unmanaged  not in state: .artifacts/canon-prod-hotfix.json
[FAIL] 2 of 6 check(s) failed: integrity, unmanaged
```

**The apply succeeded and fixed only one of the three changes.** Terraform can only detect drift in attributes its provider reads back, and `local_file` compares content, not file mode — `terraform plan` reports *No changes* on the world-writable file. And Terraform never touches objects that aren't in its state. Both have direct cloud equivalents: a console-added security-group rule next to rules managed as separate resources, a manually attached IAM policy, an instance someone launched by hand in the same subnet. Neither drift detection nor a green apply will ever report them.

Fix what's left deliberately — deleting or importing an unmanaged object is a decision, and `-replace` rebuilds an object whose drift the provider can't see:

```bash
rm envs/prod/.artifacts/canon-prod-hotfix.json && (cd envs/prod && terraform apply -auto-approve -replace='module.app_stack.local_file.stateful_store') && ./verify-env.py envs/prod
```

> **A bug this exercise caught.** The datastore was declared with `create_before_destroy = true`. The first time `-replace` ran on it, Terraform created the new file, then destroyed the old one — **at the same path** — and reported `Apply complete!` with the resource in state and nothing on disk. Only `verify-env.py`'s `exists` check noticed. `create_before_destroy` is safe only when the replacement gets a *new* name; on a fixed-name object the destroy deletes the replacement (on AWS it fails as `AlreadyExists` instead). The lifecycle block is gone, and the integration test's `replace_datastore` run guards the regression.

In a pipeline this runs as the step after every apply: a failure stops promotion from dev to prod, and in prod it pages rather than waiting for a customer to notice.

## Exercise C — the `for_each` tour

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

Exactly `web`'s four resources are destroyed: its service, listener, runbook and deploy id. `api` is untouched. Now bump only `api`'s image:

```bash
terraform plan -var 'services={api={image="api:1.5.0",cpu=256,memory=512,ports=[8080]},web={image="web:2.1.0",cpu=256,memory=512,ports=[8080]}}'
```

Only `api`'s resources change.

> **A bug this lab caught, and why it is instructive.** The first version of the module had *one* `random_id` for the whole stack, with `keepers` set to the list of service names, and every service embedded it. Removing `web` changed that one id — and **replaced `api` too**. `for_each` had isolated the services; a single shared dependency silently coupled them again. The fix was to key the dependency exactly like its consumers (`random_id.deploy[each.key]`), and a regression test now guards it. When a plan touches keys you didn't change, look for a shared upstream value.

## Exercise D — native tests: the plan, then the result

```bash
cd modules/app_stack && terraform init && terraform test
```

```text
tests/app_stack.tftest.hcl... pass
tests/integration.tftest.hcl... in progress
  run "create"... pass
  run "update_api_image"... pass
  run "remove_web"... pass
  run "replace_datastore"... pass
tests/integration.tftest.hcl... tearing down
Success! 16 passed, 0 failed.
```

Two files, two kinds of test, about two seconds together:

- **`app_stack.tftest.hcl` — 12 runs, `command = plan`.** Nothing is created. Half the suite asserts what `for_each` produces (keys, composite keys, filters, zero-instance cases); the other half uses `expect_failures` to prove the guard rails **reject** bad input.
- **`integration.tftest.hcl` — 4 runs, `command = apply`.** The runs share state and execute in order, so they walk a lifecycle: create the stack and read every object back off disk; change `api`'s image and assert against the **previous run's outputs** (`run.create.deploy_ids`) that only `api`'s deploy id rotated; remove `web` and assert its objects are really gone; `-replace` the datastore (`plan_options { replace = [...] }`) and assert it still exists. `terraform test` destroys everything when the file finishes.

The plan tests can't see apply-time values such as the random deploy ids, or whether an object survives a replacement. The integration tests can, which is how the shared-dependency bug from Exercise C and the `create_before_destroy` bug from Exercise B are both guarded.

A test is only worth something if it would fail without the thing it guards. Every assertion here was checked by mutation — the prod replica precondition, the `:latest` validation, a shared deploy-id keeper, a wrong listener target, public listeners served over HTTP, an unrendered image, deletion protection hard-coded off, a service that isn't removed, and `create_before_destroy` restored. Each mutation turns the suite red (see `RESEARCH.md`).

## Exercise E — guard rails fail in plan, not in apply

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

The reviewer sees a readable error in the pull request, rather than an API error twenty minutes into an apply that has already changed half an environment.

## Exercise F — drift detection with a record that outlives the fix

Simulate an out-of-band change, then check:

```bash
echo '{"tampered":true}' > envs/dev/.artifacts/canon-dev-api.json && ./drift-check.sh envs/dev; echo "exit=$?"
```

`terraform plan -detailed-exitcode` returns **0** (no changes), **1** (error) or **2** (drift). The script turns exit 2 into a permanent record:

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

- **The record survives remediation.** "What changed, when did we notice, how long was it that way" can only be answered if applying the fix doesn't also erase the evidence. Each record is `plan.txt` (for a human or a ticket) plus `plan.json` (for a policy engine such as OPA/conftest), made read-only on write, with a row in `drift-history/index.csv`.
- **The binary plan is not kept by default.** A `.tfplan` is valid only against the state serial that produced it, and it holds every attribute in the clear, secrets included. `KEEP_PLAN=1` retains it on purpose; otherwise it is deleted.
- **Tampering showed up as `+ create`, not an update.** `local_file`'s ID is the SHA-1 of its content, so refresh concluded the resource was gone — the same shape as a cloud resource someone deleted by hand.

## Exercise G — recovering state

**Something exists in reality but not in state** (a partial apply, a lost state write):

```bash
cd envs/dev && terraform state rm 'module.app_stack.local_file.service["api"]' && terraform plan
```

Terraform now plans to *create* `api` again. On a real provider that duplicate would collide on its name, so the fix is to **adopt** the existing object. Declaratively, since Terraform 1.5, in the root:

```hcl
import {
  to = module.app_stack.aws_ecs_service.service["api"]
  id = "canon-cluster/canon-dev-api"
}
```

An `import` block is reviewed in the PR and shows up in `plan` like any other change, which is why it beats running `terraform import` by hand. (The `local` provider doesn't implement import, so here you simply re-apply.)

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

## Exercise H — the `for_each` examples

Four self-contained roots, each with a `demo.sh` that runs the scenario, prints a one-line-per-resource plan summary, and cleans up after itself. Details in [`examples/README.md`](examples/README.md).

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
| `integration.tftest.hcl` | the same `command = apply` runs against a sandbox account, torn down at the end of the job |
| `verify-env.py` | the post-apply stage: describe calls, target health and a synthetic request through every endpoint; failure blocks promotion and pages in prod |
| `drift-check.sh` | a scheduled job per root (or Spacelift drift detection) that opens a ticket linking the record |
| a stuck lock | `terraform force-unlock <id>` — only after confirming the lock's owner is really gone |

## Cleanup

Destroy both environments, then prove the destroy really removed everything:

```bash
(cd envs/dev && terraform destroy -auto-approve); (cd envs/prod && terraform destroy -auto-approve)
```

```bash
./verify-env.py --destroyed envs/dev && ./verify-env.py --destroyed envs/prod && rm -rf drift-history
```

Expect `9 destroyed` for dev and `15 destroyed` for prod. `Destroy complete! Resources: 0 destroyed.` means that root was never applied — Terraform can only destroy what is in its state.
