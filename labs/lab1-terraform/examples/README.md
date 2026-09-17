# examples/ — `for_each`, in four runnable scenarios

Each example is a standalone root using only Terraform's built-in `terraform_data` resource. They need no providers, no network access, and cost nothing. Every `demo.sh` runs its scenario, prints a one-line-per-resource plan summary, and **cleans up after itself**, so it can be re-run any number of times.

| # | Example | The question it answers | Key result |
|---|---|---|---|
| 01 | [`count-vs-for-each`](01-count-vs-for-each/) | Why not `count`? | Removing the first user: `count` replaces 2 and destroys 1; `for_each` destroys exactly 1 |
| 02 | [`for-each-shapes`](02-for-each-shapes/) | What can `for_each` iterate, and how do I convert to it? | Sets, maps, list→map, filters, resource chaining, modules — and the "keys unknown until apply" error |
| 03 | [`nested-for-each`](03-nested-for-each/) | How do I expand service × port × CIDR? | Stable keys: adding a CIDR creates 2 rules. Positional keys: the same change *replaces* 4 |
| 04 | [`count-to-for-each-moved`](04-count-to-for-each-moved/) | How do I migrate existing `count` resources without an outage? | Without `moved`: 3 destroys + 3 creates. With `moved`: 3 moves, 0 changes, same object ids |

```bash
./01-count-vs-for-each/demo.sh
```

Requires `terraform` ≥ 1.6 and `jq`. From the repository root, `make tf-examples` runs all four.

## Reading the summaries

`_lib.sh` renders each plan from `terraform show -json`, not by scraping text:

```text
   REPLACE  terraform_data.by_index[0]        # destroy + create: the identity changed
   destroy  terraform_data.by_name["alice"]
   move     terraform_data.user["alice"]   (from terraform_data.user[0])
   ---
   0 create, 0 update, 2 replace, 2 destroy, 0 move
```

## The rules these examples add up to

1. **Use `for_each` for anything with an identity.** Use `count` only for identical, fungible copies — and for the `count = var.enabled ? 1 : 0` toggle.
2. **The key is the design.** `for_each` protects you only if the key comes from the data's identity (a name, or `service:port:cidr`). A key built from a list index (`"rule-${i}"`) brings back count's re-indexing bug.
3. **Keys must be known at plan time.** Key on names from configuration and put computed values in `each.value`.
4. **Convert lists deliberately.** `{ for x in list : x.name => x }` — and let a duplicate name fail loudly.
5. **Refactor with `moved` blocks, not `terraform state mv`.** The move is reviewed in the PR and happens automatically in every environment that applies the code.
