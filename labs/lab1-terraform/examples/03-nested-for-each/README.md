# 03 — nested `for_each`: service × port × CIDR

A realistic nested expansion: firewall rules, one per (service, port, source CIDR).

```hcl
rules_list = flatten([
  for svc_name, svc in var.services : [
    for pair in setproduct(svc.ports, svc.cidrs) : {     # every [port, cidr] pair
      service = svc_name, port = pair[0], cidr = pair[1]
    }
  ]
])

rules            = { for r in local.rules_list : "${r.service}:${r.port}:${r.cidr}" => r }   # key = identity
rules_positional = { for i, r in local.rules_list : "rule-${i}" => r }                     # key = position
```

Both maps feed a resource. They describe the same six rules and differ only in their keys.

## Run

```bash
./demo.sh
```

## Results (verified)

**Add a CIDR to `api`:**

| Keys | Plan |
|---|---|
| `api:443:172.16.0.0/12` (stable) | **2 creates**: the two new rules, nothing else |
| `rule-2` … `rule-7` (positional) | **4 replaces + 2 creates**: the new CIDR lands mid-list and shifts every later index |

**Remove port 80 from `web`:**

| Keys | Plan |
|---|---|
| stable | **1 destroy**: `web:80:0.0.0.0/0` |
| positional | 1 replace + 1 destroy, and far more churn if the removed item is near the front |

`for_each` is not what protects you — the **key** is. A positional key inside `for_each` is `count`'s bug in disguise.
On a live security group, those replacements are windows in which traffic is dropped.

## `dynamic` blocks — the same expansion inside one resource

When the provider models rules as nested blocks, use `dynamic`. This is included as a commented reference in
`main.tf`, since this example uses no cloud provider:

```hcl
dynamic "ingress" {
  for_each = setproduct(each.value.ports, each.value.cidrs)
  content {
    from_port   = ingress.value[0]
    to_port     = ingress.value[0]
    protocol    = "tcp"
    cidr_blocks = [ingress.value[1]]
  }
}
```

The trade-off: inline blocks change as **one attribute**, so any edit rewrites the group's rule set. Separate rule
resources (`aws_vpc_security_group_ingress_rule`) give you per-rule plans, per-rule drift detection, and per-rule
blast radius, which is usually worth it when rules change often.
