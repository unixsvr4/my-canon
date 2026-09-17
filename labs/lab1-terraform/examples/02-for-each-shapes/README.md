# 02 — every shape `for_each` accepts

`for_each` takes a **map** or a **set of strings**. Everything else has to be converted, and the conversion is where
you decide what the key is.

| | Input | Conversion | Address |
|---|---|---|---|
| A | list of strings | `toset(var.regions)` — also de-duplicates | `terraform_data.region["us-east-1"]` |
| B | map of objects | none | `terraform_data.team["payments"]` |
| C | list of objects | `{ for h in var.hosts : h.hostname => h }` | `terraform_data.host["gw01"]` |
| D | filtered map | `{ for n, h in local.hosts_by_name : n => h if h.role == "database" }` | `terraform_data.db_backup["db01"]` |
| E | another resource | `for_each = terraform_data.host` | `terraform_data.host_monitor["gw01"]` |
| F | a module | `module "bucket" { for_each = var.teams ... }` | `module.bucket["payments"].terraform_data.bucket` |
| G | a computed value | `toset([terraform_data.seed.id])` | **error** — see below |

Also shown: grouping with the `...` operator, which turns duplicate keys into lists instead of an error:

```hcl
hostnames_by_role = { for h in var.hosts : h.role => h.hostname... }
# { database = ["db01"], gateway = ["gw01", "gw02"] }
```

## Run

```bash
./demo.sh
```

The demo triggers G against empty state, applies A–F, prints every resource address, and then changes one team's
budget to show that only `terraform_data.team["payments"]` updates.

## G: "Invalid for_each argument"

`for_each` keys become resource addresses, so Terraform must know them **at plan time**. A key derived from something
created during apply (an id, a generated name) fails:

```text
Error: Invalid for_each argument
... cannot be determined until apply ...
```

The fix is always the same: key on a value you already know from configuration, and put the computed value in
`each.value`. Using `-target` to create the dependency first works once, but it is a manual step every new
environment would need.

See [`modules/bucket/README.md`](modules/bucket/README.md) for the module used in F.
