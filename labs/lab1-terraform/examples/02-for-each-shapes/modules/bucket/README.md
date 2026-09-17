# modules/bucket

A one-resource module that exists only so example 02 can demonstrate `for_each` on a **module call**:

```hcl
module "bucket" {
  source   = "./modules/bucket"
  for_each = var.teams          # one whole module instance per team

  name  = "canon-${each.key}-artifacts"
  owner = each.value.owner
}
```

The design rule it illustrates: **a module describes one thing; the caller decides how many.** There is no
`for_each` inside it and no knowledge of how many copies exist. Instances are addressed
`module.bucket["payments"].terraform_data.bucket`, and `module.bucket` itself is a map you can iterate in outputs:
`{ for team, m in module.bucket : team => m.name }`.
