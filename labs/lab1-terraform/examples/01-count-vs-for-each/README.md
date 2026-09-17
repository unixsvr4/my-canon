# 01 — `count` vs `for_each`

Two resources manage the same three users. The only difference is how each instance is addressed:

```hcl
resource "terraform_data" "by_index" {        # terraform_data.by_index[0], [1], [2]
  count            = length(var.users)
  triggers_replace = var.users[count.index]
}

resource "terraform_data" "by_name" {         # terraform_data.by_name["alice"], ["bob"], ["carol"]
  for_each         = toset(var.users)
  triggers_replace = each.key
}
```

`triggers_replace` stands in for a ForceNew attribute on a real resource, such as an IAM user name, a bucket name, or a VM
hostname: change it, and the object is destroyed and recreated.

## Run

```bash
./demo.sh
```

## Result (verified)

Removing `"alice"`, the first element:

```text
   REPLACE  terraform_data.by_index[0]      # was alice, now bob
   REPLACE  terraform_data.by_index[1]      # was bob, now carol
   destroy  terraform_data.by_index[2]
   destroy  terraform_data.by_name["alice"]
   ---
   0 create, 0 update, 2 replace, 2 destroy, 0 move
```

With `count`, `bob` and `carol` slide down one index, so Terraform sees their identities change and rebuilds them. On
a real IAM user, that means revoked access keys; on a VM, a new machine. With `for_each`, exactly `alice` is destroyed.

## Why `toset()`

`for_each` accepts a map or a **set** of strings, never a list. A list has an order, and order is exactly the positional
identity `for_each` exists to remove. `toset()` also de-duplicates.

## When `count` is right

Identical, interchangeable copies with no individual identity. The idiomatic conditional toggle is:

```hcl
count = var.enable_bastion ? 1 : 0
```
