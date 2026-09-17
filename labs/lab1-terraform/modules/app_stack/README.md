# Module: `app_stack`

A service stack, modelled with `$0` local resources whose **structure** is what you'd write against a cloud
provider. `main.tf` is laid out as a guided tour of `for_each`, simplest pattern first.

## Resources and the pattern each one demonstrates

| Resource | `for_each` over | Key example | Stands in for |
|---|---|---|---|
| `random_id.deploy` | `var.services` | `["api"]` | a per-service deploy/revision id |
| `local_file.service` | `var.services` (map of objects) | `["api"]` | `aws_ecs_service` + task definition |
| `local_file.listener` | `local.listeners` (flattened service × port) | `["api-443"]` | `aws_lb_listener` |
| `local_file.public_endpoint` | `local.public_services` (filtered map) | `["api"]` | Route 53 record + target group |
| `local_file.runbook` | `local_file.service` (another resource) | `["api"]` | a per-service dashboard |
| `local_file.stateful_store` | *nothing — singleton on purpose* | — | `aws_db_instance` |

### Why each pattern exists

- **Map of objects.** The map key becomes the resource address. Removing a service destroys exactly that service;
  its neighbours keep their addresses and are never touched.
- **Flatten to a composite key.** `for_each` needs one flat map, and the input is nested (services contain port
  lists). `flatten()` plus a `for` expression produces `{"api-443" = {...}, "api-8443" = {...}}`. The key is
  derived from the data (`service-port`), so adding or removing a port changes only that listener. A validation
  rejects duplicate ports before they can become a duplicate key.
- **Filtered map.** `{ for k, v in var.services : k => v if v.public }` makes a resource conditional *per key*. In
  dev nothing is public and the resource has zero instances — no `count` ternary needed.
- **`for_each` over another resource.** `for_each = local_file.service` iterates that resource's instances: the
  keys match, and `each.value` is the resource object, so apply-time attributes are available. Adding a service
  automatically adds its runbook.
- **No `for_each`.** A datastore has its own lifecycle. Putting it in the services map would leave stateful data one
  tfvars typo away from a destroy.
- **Dependencies keyed like their consumers.** `random_id.deploy` is per service. A single shared id once coupled every
  service together — see the regression test and the Lab 1 README, Exercise B.

## Inputs

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `name_prefix` | `string` | yes | — | `^[a-z][a-z0-9-]{2,30}$` |
| `environment` | `string` | yes | — | `dev` \| `staging` \| `prod` |
| `services` | `map(object)` | yes | — | see below; at least one entry |
| `tags` | `map(string)` | no | `{}` | merged over the module's mandatory tags |
| `deletion_protection` | `bool` | no | `true` | safe by default; dev opts out explicitly |

`services` object attributes:

| Attribute | Type | Default | Validation / guard rail |
|---|---|---|---|
| `image` | `string` | required | explicit tag, never `:latest` or untagged |
| `cpu` | `number` | required | `memory >= 2 × cpu` (precondition) |
| `memory` | `number` | required | |
| `desired_count` | `number` | `1` | `>= 2` in prod (precondition) |
| `public` | `bool` | `false` | public services must list at least one port (precondition) |
| `ports` | `list(number)` | `[]` | 1–65535, unique per service |

## Outputs

| Name | Shape |
|---|---|
| `service_names` | `{ api = "canon-dev-api", ... }` |
| `listeners` | `{ "api-443" = 443, ... }` |
| `public_endpoints` | `{ api = "api.prod.canon.example", ... }` — empty map if nothing is public |
| `deploy_ids` | `{ api = "9b0311c3", ... }` |
| `artifact_dir` | path where the stand-in resources are written |

Outputs are maps keyed like the input. A list built from a `for_each` resource has an ordering nobody should depend
on.

## Usage

```hcl
module "app_stack" {
  source = "../../modules/app_stack"

  name_prefix = "canon-prod"
  environment = "prod"
  tags        = { Owner = "platform", CostCenter = "infra-prod" }

  services = {
    api    = { image = "api:1.4.2", cpu = 512, memory = 2048, desired_count = 3, public = true, ports = [443, 8443] }
    worker = { image = "worker:0.9.1", cpu = 256, memory = 1024, desired_count = 2 }
  }
}
```

## Tests

```bash
terraform init && terraform test
```

See [`tests/README.md`](tests/README.md).
