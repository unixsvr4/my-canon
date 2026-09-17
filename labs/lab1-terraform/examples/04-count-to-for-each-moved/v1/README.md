# v1 — legacy `count` implementation

The "already in production" starting point for example 04: three users managed with `count` over a list, addressed `terraform_data.user[0]`, `[1]` and `[2]`. The demo copies this `main.tf` into a scratch directory and applies it to create the state the refactor has to preserve. Don't apply this directory directly.
