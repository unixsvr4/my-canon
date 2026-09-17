# modules/app_stack/tests

Native Terraform tests (`terraform test`, Terraform 1.6+). Run them from the module directory:

```bash
cd .. && terraform init && terraform test
```

## What the suite covers

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

## Two things worth knowing about `terraform test`

- **A plan-only assertion can't read apply-time values.** An early version asserted on a service's rendered
  `content`, which embeds a random id, and failed with *"Condition expression could not be evaluated at this
  time."* Assert on what is known at plan (keys, variables, filenames), or use `command = apply` for runs that need
  computed values.
- **`expect_failures` tests need a mutation check.** A run that expects a failure passes whenever *something*
  fails. Temporarily removing the guard and watching the test go red is the only way to know it tests that guard.
  This was done for the prod precondition and the `:latest` validation.
