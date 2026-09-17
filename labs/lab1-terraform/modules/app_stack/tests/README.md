# modules/app_stack/tests

Native Terraform tests (`terraform test`, Terraform 1.6+). Two files, two kinds of test: **the plan** (`app_stack.tftest.hcl`) and **the result** (`integration.tftest.hcl`). Run them from the module directory:

```bash
cd .. && terraform init && terraform test
```

## `app_stack.tftest.hcl` — unit tests against the plan

Every run uses `command = plan`, so nothing is created. The suite is fast, free, and safe to run on every pull request.

| Run | Kind | Asserts |
|---|---|---|
| `service_instances_are_keyed_by_name` | behaviour | one instance per map key; names derived from prefix + key |
| `listeners_use_composite_service_port_keys` | behaviour | flatten produces `api-443`, `api-8443`, `web-443` — and nothing for a service with no ports |
| `only_public_services_get_endpoints` | behaviour | the filtered map keeps only `public = true` |
| `no_public_services_means_zero_instances` | behaviour | an empty filtered map yields zero instances, not an error |
| `runbooks_follow_services` | behaviour | `for_each` over another resource keeps the same keys |
| `deploy_ids_are_keyed_per_service` | regression | no single shared dependency re-coupling the instances |
| `optional_attributes_take_defaults` | behaviour | `optional()` defaults applied |
| `prod_rejects_a_single_replica` | guard rail | `expect_failures = [local_file.service]` |
| `rejects_latest_image_tag` | guard rail | `expect_failures = [var.services]` |
| `rejects_duplicate_ports` | guard rail | `expect_failures = [var.services]` |
| `rejects_public_service_without_ports` | guard rail | `expect_failures = [local_file.public_endpoint]` |
| `rejects_unknown_environment` | guard rail | `expect_failures = [var.environment]` |

## `integration.tftest.hcl` — integration tests against what was built

Every run uses `command = apply`: it creates real objects, reads them back **off disk** with `file()` (not from state), and `terraform test` destroys everything when the file finishes. The runs share state and execute in order, so together they walk one lifecycle.

| Run | Step | Asserts, against the real objects |
|---|---|---|
| `create` | apply the stack | every object in state exists; image and replicas on disk match the input; each service carries its own applied deploy id; every listener's target exists; internet-facing listeners are HTTPS; endpoint ports; mandatory tags; deletion protection; the runbook lists its listeners |
| `update_api_image` | bump only `api`'s image | `api`'s deploy id rotated and `web`'s didn't — compared with `run.create.deploy_ids`, the previous run's output; the new image reached the object |
| `remove_web` | drop `web` from the map | `web`'s four objects are gone from disk, not orphaned; `api` untouched |
| `replace_datastore` | `plan_options { replace = [local_file.stateful_store] }` | the datastore still exists after a replacement (regression for T11 in `RESEARCH.md`) |

### Mutation check

Each assertion was proven by breaking the module in a scratch edit and watching the suite go red:

| Mutation | Caught by |
|---|---|
| deploy-id `keepers` include every service name (shared dependency) | `remove_web` — changing one image doesn't rotate the others, but removing a service does |
| listener `target` points at a path that doesn't exist | `create` |
| every listener rendered as `HTTP` | `create` |
| image hard-coded instead of rendered from input | `create`, `update_api_image` |
| `deletion_protection` hard-coded `false` | `create` |
| `web` left in the map in the removal step | `remove_web` |
| `create_before_destroy = true` restored on the datastore | `replace_datastore` |

## Things worth knowing about `terraform test`

- **An apply run can assert on the real world.** `file()` and `fileexists()` in an `assert` are evaluated after the apply, so they read what was actually written. Against a cloud provider the same role is played by a data source declared in the test's module, or a `check` block with an `http` probe.
- **Runs can compare against earlier runs.** `run.<name>.<output>` is how `update_api_image` proves *only* `api` changed, without hard-coding a random value.
- **A plan-only assertion can't read apply-time values.** An early version asserted on a service's rendered `content`, which embeds a random id, and failed with *"Condition expression could not be evaluated at this time."* Assert on what is known at plan (keys, variables, filenames), or use `command = apply` for runs that need computed values.
- **`expect_failures` tests need a mutation check.** A run that expects a failure passes whenever *something* fails. Temporarily removing the guard and watching the test go red is the only way to know it tests that guard. This was done for the prod precondition and the `:latest` validation.
