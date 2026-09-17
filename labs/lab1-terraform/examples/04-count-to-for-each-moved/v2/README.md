# v2 — the `for_each` refactor

| File | Purpose |
|---|---|
| `main.tf` | the same users, now `for_each = var.users` and addressed `terraform_data.user["alice"]` |
| `moved.tf` | one `moved` block per instance, mapping each old index to its new key |

The demo copies `main.tf` alone first, to show the destroy-and-recreate plan, and then adds `moved.tf` to show the zero-change migration. Keeping the moves in a separate file makes them easy to find and easy to delete once every environment has applied them.
