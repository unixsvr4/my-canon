# modules/

Reusable Terraform modules. **All resource logic in this lab lives here**; the environment roots in `../envs/` only
pass inputs.

| Module | What it models | Read first |
|---|---|---|
| [`app_stack/`](app_stack/) | A service stack: services, listeners, public endpoints, runbooks, a datastore | [`app_stack/README.md`](app_stack/README.md) |

## Module design rules used here

1. **No `provider` blocks inside a module.** Only `required_providers` constraints. The caller configures providers
   (region, credentials, assume-role), so one module version runs in any account or region.
2. **Inputs are a contract.** Precise types (`object` with `optional()` attributes, never `any`), no defaults on
   required inputs, safe defaults on optional ones, and `validation` blocks whose messages tell the caller how to fix
   the input.
3. **Outputs are the public interface.** Callers depend on outputs, never on internal addresses, so internals can be
   refactored with `moved` blocks without breaking anyone.
4. **A module describes one thing; the caller decides how many.** Multiplicity comes from `for_each` on the input
   map, or `for_each` on the module call itself (see `../examples/02-for-each-shapes`).
5. **Tested in isolation.** `terraform test` runs against the module directly, with no environment root involved.

## Versioning in production

Here, roots reference the module by relative path so the lab is self-contained. In a real repository the module is
consumed at a pinned version:

```hcl
source = "git::https://github.com/canon/terraform-modules.git//app_stack?ref=v1.4.0"
```

A module change is released as a new tag, soaks in dev and staging, and reaches prod as a one-line ref bump that is
reviewed like any other change.
