# Tests for the AWS `app_stack` module

**22 runs, 0 failures, ~2.7 s, no AWS account.**

```bash
cd labs/lab1-terraform/aws/modules/app_stack && terraform test
```

```bash
terraform test -filter=tests/unit.tftest.hcl          # the 18 plan-time runs
terraform test -filter=tests/integration.tftest.hcl   # the 4 apply-time runs
```

| File | Runs | Command | Proves |
|---|---|---|---|
| [`unit.tftest.hcl`](unit.tftest.hcl) | 18 | `plan` | the plan is right: `for_each` shapes, composite keys, security posture that is knowable from configuration, and eleven guard rails watched rejecting bad input |
| [`integration.tftest.hcl`](integration.tftest.hcl) | 4 | `apply` | the result is right: every reference lands on its own partner, and changing one service leaves the others alone |

Both use `mock_provider "aws"`, so nothing is created and nothing is charged.

## The plan-time runs

Seven positive runs on the `for_each` structure and the posture:

| Run | Asserts |
|---|---|
| `one_service_per_map_key` | 3 services → 3 task definitions, 3 services, 3 task roles, 3 log groups |
| `flattened_keys_are_service_and_port` | keys are exactly `api-443`, `api-8443`, `web-443`; listeners deduplicated to `443`/`8443`; priorities derived from **sorted** keys so adding a service does not renumber the others |
| `filtered_map_excludes_private_services` | the private `worker` gets no DNS record and no listener rule — no `count` ternary anywhere |
| `alarms_follow_the_service_resource` | one alarm per service, and `treat_missing_data = breaching` on the "are the tasks alive" alarm |
| `security_posture` | HTTPS on a TLS 1.3/1.2 policy, port 80 redirects rather than forwards, invalid headers dropped, RDS encrypted and not public, master password managed by RDS, CMK rotation on, no public IPs on tasks, explicit log retention |
| `mandatory_tags_on_every_taggable_resource` | the five mandatory tags on the database, a `Service` tag per service resource (what lab 2's inventory groups on), and caller tags merging **over** rather than replacing |
| `target_group_name_prefix_fits_the_api_limit` | ≤ 6 characters, because `create_before_destroy` forces `name_prefix` and the ELB API caps it there |

Then eleven negative runs. A guard rail nobody has watched fail is a guard rail nobody knows works, so each of these is an input a real deployment would have accepted and regretted:

`:latest` or an untagged image · a Fargate cpu the API does not accept · the same port twice on one service · a public service with no ports · a service key that cannot be part of a resource name · one subnet where two AZs are needed · a malformed VPC id · a log retention CloudWatch does not accept · **prod with one task** · **prod with deletion protection off** · **prod on a `db.t4g.micro`**

The last three are `precondition`s rather than variable `validation`s, because they depend on `var.environment` — the same input being validated. They fail in the plan, per resource, with a message a reviewer reads in the pull request.

## The apply-time runs

Four runs sharing state, in order, each a lifecycle step.

| Run | What it does | The assertions that matter |
|---|---|---|
| `create` | applies the stack | every listener rule is on **its own port's** listener and forwards to **its own service's** target group; each service runs its own task definition and registers into its own target group; each task definition uses its own service's task role and log group; the database credential arrives as a `secrets` reference and **not** in `environment`; one CMK for logs, database, secret and Performance Insights; records alias the ALB with target-health evaluation; alarms watch the real applied service names and thresholds; prod is Multi-AZ with 30-day backups and a final snapshot; the outputs match the applied resources |
| `update_api_image` | bumps only `api`'s image | `api`'s digest moves, **`web`'s does not** — the coupling test |
| `remove_web` | removes `web` from the map | `web`'s target group, log group, task role and listener rule are all gone; nothing keyed to `web` is orphaned; `api` is untouched |
| `add_a_port` | adds 9443 to `api` | exactly one new listener key; a third listener exists and the new rule is on it; the container's `portMappings` now include 9443 |

`terraform test` destroys everything it created, in reverse run order, when the file finishes. Against mocks that is instant; against a real sandbox account it is the same code and the same teardown.

### One assertion that was wrong, and what it taught

`add_a_port` originally asserted that adding a port must **not** change the service's task definition — "a port is a load-balancer concern". The test failed, and the module was right: the container has to *listen* on the port, so it appears in `portMappings` and the definition legitimately changes.

Worth knowing before a change window: **"just add a port to the ALB" is a redeploy of the service**, not a load-balancer-only edit. The assertion now states that, and the comment records that the first version claimed the opposite.

## Mutation testing

A passing test proves nothing until it has been watched failing. Each mutation was applied to a scratch copy of the module, the suite was run, and the module restored.

| # | Mutation | Caught by |
|---|---|---|
| 1 | a shared value (`join(",", keys(var.services))`) embedded in every task definition | `remove_web` — **not** `update_api_image`: bumping an image does not change the *set* of service names, so `web`'s digest only moves when a service is added or removed. The same behaviour as the local module's equivalent mutation. |
| 2 | every listener rule forwards to `api`'s target group | `create` |
| 3 | one shared task role instead of one per service | `create` |
| 4 | the database credential moved from `secrets` into `environment` | `create` |
| 5 | the public listener downgraded to HTTP | `security_posture` |
| 6 | the prod replica precondition removed | `prod_refuses_a_single_task` |
| 7 | `readonlyRootFilesystem` turned off | `create` |
| 8 | the alarm pointed at a hard-coded name instead of `each.value.name` | `create` |
| 9 | one shared log group for every container | `create` |
| 10 | listener rules keyed per service instead of per service × port | `flattened_keys_are_service_and_port` **and** `add_a_port` |
| 11 | the database encrypted with a different key | `create` |

Mutation 1 is the one to notice. It is the AWS form of [`RESEARCH.md`](../../../../../../RESEARCH.md) **T1** — one shared `random_id` meant removing `web` replaced `api` — and it is caught at run 3 rather than run 2, for a reason worth understanding: an image change does not alter the set of service names, so a dependency keyed on that set stays stable until the set itself changes. A test suite that only ever bumped an image would have missed it.

## What these tests cannot do

`mock_provider` removes the API call, not the provider's rules and not AWS's. A mock accepts an invalid subnet id, an ALB name already taken in the account, a Fargate cpu/memory pair the API rejects, an IAM policy that denies what the task needs, or a quota you have already reached. And because it does not model force-replacement, *"was this replaced?"* is not a question it can answer — which is why the isolation assertions compare Terraform-computed digests rather than provider-assigned ARNs.

The other gates cover what mocks cannot: variable validations, `tflint`'s AWS ruleset (provider-aware: invalid instance types, deprecated arguments, names over the API limit), `trivy`'s misconfiguration policy, and one periodic apply into a sandbox account. The three mock behaviours that cost real time — random ARNs failing format validation, type-wide defaults making per-key assertions vacuous, and no force-replacement — are documented at the top of both test files, next to the code that works around them. See [`../../../README.md`](../../../README.md) for the longer version.
