# envs/prod

The production root: same module, same version, stricter inputs.

- `api` and `web` are **public**, so they get listeners on their ports *and* public endpoints (filtered `for_each`).
- `worker` has **no ports**, so the flattened listener map and the filtered endpoint map simply contain nothing for it — no special-casing anywhere.
- Every service has `desired_count >= 2`. The module refuses anything less in prod, at plan time.
- `deletion_protection = true`, plus a `Compliance` tag.

```bash
terraform init && terraform plan
```

Expected: 15 resources — 3 services, 3 listeners (`api-443`, `api-8443`, `web-443`), 2 public endpoints, 3 runbooks, 3 deploy ids, 1 datastore.

Try breaking a guard rail (the plan fails with a readable message; nothing is applied):

```bash
terraform plan -var 'services={api={image="api:1.4.2",cpu=512,memory=1024,desired_count=1}}'
```

In a real pipeline this root has its own role, its own state bucket in a separate account, and a required approval before apply.
