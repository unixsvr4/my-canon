# envs/dev

The development root: two internal services, nothing public, deletion protection explicitly **off** so the environment can be torn down and rebuilt at will.

| File | Purpose |
|---|---|
| `main.tf` | backend (local here; the S3 configuration is in the comments) and the module call |
| `variables.tf` | the root's typed inputs — errors point at *this* environment's tfvars |
| `terraform.tfvars` | dev's actual values |
| `.terraform.lock.hcl` | pinned provider builds — committed |

```bash
terraform init && terraform plan -out=tfplan && terraform apply tfplan && terraform output
```

Expected: 9 resources — 2 services, 2 listeners (`api-8080`, `web-8080`), 0 public endpoints, 2 runbooks, 2 deploy ids, 1 datastore.

Then test what was built, not just that the apply succeeded:

```bash
../../verify-env.py envs/dev
```

This is also the root that `../../drift-check.sh envs/dev` checks in Exercise F. Tear it down with `terraform destroy -auto-approve` (9 destroyed), then `../../verify-env.py --destroyed envs/dev`.
