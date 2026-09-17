# envs/

One directory per environment. Each is a **thin root module**: it chooses a state backend and passes inputs to `../modules/app_stack`. It contains no resource logic.

| Root | Services | Public | Guard rails active |
|---|---|---|---|
| [`dev/`](dev/) | `api`, `web` | none | image tags, port uniqueness |
| [`prod/`](prod/) | `api`, `web`, `worker` | `api`, `web` | + `desired_count >= 2`, public services must expose ports |

## Why directories and not workspaces

Workspaces share one configuration and one backend, and switching is a local CLI setting. That makes "which environment am I about to change?" a property of somebody's terminal. Separate directories give each environment:

- its **own state file** and backend key, so a plan in dev physically can't read or lock prod state;
- its **own credentials**, with CI assuming a different role per root;
- its **own pipeline and approval gate**, so prod applies can require a second reviewer;
- its **own `.terraform.lock.hcl`**, committed, so provider builds are pinned per environment.

The cost is a few duplicated lines (`main.tf`, `variables.tf`). Those lines are the environment's contract, so repeating them is useful.

## Running a root

```bash
cd dev && terraform init && terraform plan -out=tfplan && terraform apply tfplan
```

Stand-in resources are written to `<root>/.artifacts/` (gitignored). `path.root` in the module points there, so dev and prod never write to each other's files.
