# 04 — migrating `count` → `for_each` with `moved` blocks

Example 01 shows why `count` is the wrong tool. This one handles what happens next: the `count` version is already
deployed and holding real state, and you need to refactor it **without destroying anything**.

| Directory | Contents |
|---|---|
| [`v1/`](v1/) | the legacy code: `count = length(var.users)` |
| [`v2/`](v2/) | the refactor: `for_each = var.users`, plus `moved.tf` |

Changing `count` to `for_each` changes every address (`user[0]` → `user["alice"]`). Terraform treats a new address as
a new object, so without help this *pure refactor* plans a full destroy and recreate.

## Run

```bash
./demo.sh
```

The demo deploys v1 in a scratch directory, applies the v2 refactor twice (without and then with `moved.tf`), and
compares object ids before and after.

## Results (verified)

```text
== 2. Refactor to v2 (for_each) WITHOUT moved blocks, and plan
   3 create, 0 update, 0 replace, 3 destroy, 0 move

== 3. Same refactor WITH moved.tf, and plan
   move     terraform_data.user["alice"]   (from terraform_data.user[0])
   move     terraform_data.user["bob"]   (from terraform_data.user[1])
   move     terraform_data.user["carol"]   (from terraform_data.user[2])
   0 create, 0 update, 0 replace, 0 destroy, 3 move

== 4. Apply it and confirm the objects survived
   alice id before: "ca31d19d-..."
   alice id after:  "ca31d19d-..."
   -> same object, new address. Nothing was recreated.
```

## Why `moved` blocks instead of `terraform state mv`

| `moved` block | `terraform state mv` |
|---|---|
| reviewed in the pull request | typed into a terminal |
| shown in `plan` before anything happens | takes effect immediately |
| applies itself in **every** environment that runs the code | must be repeated by hand against every state file |
| survives in history as documentation of the refactor | leaves no trace in code |

**Keep `moved` blocks for at least one release**, until every environment has applied past them. If a block is removed
before a lagging environment applies it, that environment gets the destroy-and-recreate plan after all.

The same mechanism handles moving resources into a module (`to = module.users.terraform_data.user`) and renaming
modules.
