# Lab 1 — AWS: the real implementation, apply-tested without an AWS bill

The module one directory up models ECS services, listeners, DNS records and a database with `local_file` resources, so the lab runs offline at **$0**. This is the same module against the real `aws` provider: same input contract, same `for_each` shapes, same guard rails, real resources.

**22 `terraform test` runs — 18 plan-time and 4 apply-time — against a mocked AWS. No credentials, no account, no cost, 2.7 seconds.** Plus `terraform validate`, the provider-aware `tflint` AWS ruleset, and a `trivy` misconfiguration gate that now has teeth.

```bash
make lab1-aws-static    # init -backend=false, validate, tflint with the aws ruleset
make lab1-aws-test      # 22 runs against mock_provider
make lab1-scan          # trivy over all the Terraform, local and AWS
```

## What is here

```text
aws/
├── .tflint.hcl                       # the aws ruleset: provider-aware linting
├── modules/app_stack/                # the real module
│   ├── main.tf                       # A. for_each over a map -> task definitions, services
│   ├── alb.tf                        # B. for_each over a FLATTENED map -> listener rules
│   ├── dns.tf                        # C. for_each over a FILTERED map -> Route 53 records
│   ├── observability.tf              # D. for_each over ANOTHER RESOURCE -> alarms
│   ├── database.tf                   # E. no for_each, and why -> RDS
│   ├── iam.tf                        # execution role (shared) vs task roles (per service)
│   ├── data.tf                       # partition/account/region, policy documents, derived locals
│   └── tests/                        # unit.tftest.hcl + integration.tftest.hcl
└── envs/
    ├── bootstrap/                    # the state bucket and the keyless CI identity
    ├── dev/                          # thin root: backend, provider, inputs
    └── prod/                         # the same module, a different account, different data
```

## Apply-testing AWS with no AWS

`mock_provider "aws"` (Terraform 1.7+) answers every provider call locally, so `command = apply` runs the whole graph — creating, updating, removing and destroying — in about a second, with no credentials and no charges. That is what makes apply-time assertions affordable enough to run on every commit:

```hcl
run "create" {
  command = apply

  assert {
    condition = alltrue([
      for key, rule in aws_lb_listener_rule.this :
      rule.action[0].target_group_arn == aws_lb_target_group.this[local.listeners[key].service].arn
    ])
    error_message = "a listener rule forwards to another service's target group"
  }
}
```

That comparison cannot be made at plan time — both ARNs are unknown until apply — and it is exactly the kind of mistake that reaches production, because a rule pointing at the wrong target group is syntactically perfect and serves the wrong service's traffic.

### What mocks prove, and what they do not

Worth being precise about, because "22 tests pass" would otherwise sound like more than it is.

**They prove:** the graph resolves; every reference lands on its intended partner; the `for_each` keys are what they should be; changing one service leaves the others untouched; removing a service removes everything keyed to it; the guard rails reject the inputs they are meant to reject.

**They cannot prove:** anything about AWS. A mock accepts an invalid subnet id, an ALB name already taken in the account, a Fargate cpu/memory pair the API rejects, an IAM policy that denies what the task needs, or a service quota you have already hit. That is what the other three gates are for — the variable validations, `tflint`'s provider-aware rules, `trivy`'s policy — plus one periodic apply into a sandbox account. **Mocks buy speed and zero cost, not certainty.**

### Three things mocks do that will cost you an afternoon

All three were hit while writing these tests, and all three are in the test files with the reasoning next to them.

1. **A mock invents a random 8-character string for every computed attribute, and the provider still validates format.** So `load_balancer_arn = aws_lb.this.arn` fails the apply with `"load_balancer_arn" (g37mq6n0) is an invalid ARN: arn: invalid prefix`. Plan-only runs never hit this — at plan the value is unknown and validation skips unknowns — so it appears the moment a run becomes `command = apply`. The same goes for anything another resource *parses*: `aws_iam_policy_document.json` needs a realistic default or every role fails with `contains an invalid JSON policy: not a JSON object`.

2. **The obvious fix quietly destroys the test.** `mock_resource` defaults apply to **every instance of that type**, so defaulting `aws_lb_target_group.arn` gives `api` and `web` the *same* ARN — and every "each rule forwards to its own service's target group" assertion then passes while proving nothing. A fixed default is only safe where the module has exactly one of something (the load balancer, the CMK). Everything per-key needs `override_resource`, which targets one address and keeps the values distinct. `mock_resource` is per **type**; `override_resource` is per **address**.

3. **A mock does not model force-replacement.** It generated the task definition's ARN once and returns the same value even where a real apply would cut a new revision, so *"was this resource replaced?"* is not a question a mock can answer. An assertion phrased that way passes for the wrong reason. The module therefore publishes `task_definition_digests` — a digest of the rendered definition, computed by Terraform rather than by the provider — which is honest in a mocked test, identical in behaviour against a real account, and useful in its own right: it is how CI answers "did this commit actually change the api service?" without calling AWS.

That third point is why the coupling test — the AWS form of [`RESEARCH.md`](../../../RESEARCH.md) T1, where one shared `random_id` meant removing `web` replaced `api` — compares digests:

```hcl
assert {
  condition     = output.task_definition_digests["web"] == run.create.task_definition_digests["web"]
  error_message = "web was not changed, so its definition must not move (cross-service coupling)"
}
```

Every assertion was mutation-checked: [`modules/app_stack/tests/README.md`](modules/app_stack/tests/README.md) has the table of 11 module mutations and which run caught each.

## The `for_each` tour, in real resources

Same five patterns as the local module, same order, so the two can be read side by side.

| | Pattern | Local module | AWS |
|---|---|---|---|
| **A** | map of objects | `local_file.service` | `aws_ecs_task_definition` + `aws_ecs_service` + a task role and log group per service |
| **B** | flattened nested map, composite key `api-8443` | `local_file.listener` | `aws_lb_listener_rule`, one per service × port, on a **shared** ALB |
| **C** | filtered map (zero instances when nothing matches) | `local_file.public_endpoint` | `aws_route53_record` for public services only |
| **D** | another resource's instances | `local_file.runbook` | `aws_cloudwatch_metric_alarm` `for_each = aws_ecs_service.this` |
| **E** | no `for_each`, deliberately | `local_file.stateful_store` | `aws_db_instance` |

Three different `for_each` sources appear in `alb.tf` alone, because the three resources are keyed by three different things: target groups per **service**, listeners per distinct **port**, rules per **service × port**. Forcing them onto one key is how modules end up with rules they cannot remove individually.

`aws_vpc_security_group_ingress_rule` (one rule per resource) rather than inline `ingress` blocks is the same lesson as [`examples/03-nested-for-each`](../examples/03-nested-for-each/), where adding one CIDR to an inline block replaced **4 firewall rules just to add one**. One key is one API object.

## `create_before_destroy`: same flag, opposite conclusion

The local module *removed* `create_before_destroy` from its datastore, because that object has a fixed name and create-then-destroy at one fixed name deletes the replacement while reporting success ([`RESEARCH.md`](../../../RESEARCH.md) T11).

The ALB target group *requires* it — and therefore requires `name_prefix`:

A target group attached to a listener cannot be deleted, so any change that forces replacement **deadlocks** on a fixed name: Terraform tries to destroy the old group first and the API refuses because the listener still references it. `create_before_destroy` fixes the ordering, but then two groups exist at once and they cannot share a name — so the name has to be generated. AWS caps `name_prefix` at **six characters**, which is a limit that bites at apply time, in one region, twenty minutes in. There is a test for it.

The deciding question is the same one in both cases: **does the replacement get a new name?**

## Security decisions worth reading

| Decision | Why |
|---|---|
| `manage_master_user_password = true` | RDS generates and rotates the credential into Secrets Manager, so **the password never enters Terraform state**. With `password = ...` it is in the state file forever, in plaintext, readable by anyone who can read the state bucket. The task definition consumes the secret ARN. |
| credentials as `secrets`, never `environment` | an environment variable is visible in the task definition, in `describe-task-definition`, and to anyone with console read access. There is an apply-time assertion for this. |
| one execution role, **task roles per service** | the execution role is the ECS *agent* (pull the image, fetch the secret, create the log stream); the task role is the *application*. Putting the application's permissions on the execution role works, which is why it survives review — and it means every container on the cluster inherits the union of every service's permissions. |
| log groups created here | a group created implicitly by the first task has no retention (billed forever), no KMS key and no tags, and survives `terraform destroy` because nothing owns it. |
| one CMK for logs, database, secret and Performance Insights | there is an apply-time assertion that nothing quietly landed on a second, AWS-managed key — which is invisible until an audit. |
| `deployment_circuit_breaker` with rollback | without it a broken image is a deploy that never finishes: ECS keeps starting tasks that keep dying until someone notices. |
| `readonlyRootFilesystem`, non-root user, `initProcessEnabled` | turns "attacker writes a webshell into the app directory" into a failed write; reaps zombies. |
| `aws_partition` instead of `"aws"` in ARNs | hard-coding it is the most common reason a module cannot be used in GovCloud or China without editing it. |
| `treat_missing_data` chosen per alarm | `breaching` for "are the tasks alive" (no metric usually means no task to report one); `notBreaching` for 5xx counts (no requests means no errors). One global setting is wrong for one of the two. |

## The scan gate now has teeth

`trivy config` over the local-only module found nothing, because `local_file` has no security surface — the gate existed for the day there was a real provider. There is one now, and it found real things. Two findings remain, both waived **in the code, with the reason next to them**, so everything else stays a hard failure:

| Waiver | Reason |
|---|---|
| `AVD-AWS-0053` internet-facing ALB | it is meant to be: HTTPS-only listeners, ingress restricted to `var.public_ingress_cidrs`. An internal stack is a different module *call*, not a different module. |
| `AVD-AWS-0104` egress to `0.0.0.0/0` | restricted to **one port**, 443, for ECR, Secrets Manager, CloudWatch and SSM. The real fix is interface VPC endpoints and deleting the rule; until the network provides them, this is the honest state of it. |
| `AVD-AWS-0177` RDS deletion protection | driven by `var.deletion_protection`, which **defaults to true**, and a precondition refuses `prod` with it off — a stronger guarantee than a literal, because it cannot be switched off for prod in a hurry without the plan failing and saying why. |
| `AVD-AWS-0089` state bucket access logging | CloudTrail S3 data events record the **IAM identity** behind each read and write, which is the question you actually ask about state. Server access logs are best-effort, delayed and identity-poor. |

A waiver with a reason in the diff is reviewable. A scanner configuration file full of suppressed rule ids is not.

## `envs/bootstrap`: the chicken-and-egg root

Terraform needs somewhere to keep state before any root can initialise, and CI needs an identity before it can run. This root creates both, and it is the one root whose own state starts local and is then migrated into the bucket it just made.

- **State bucket** with versioning (a corrupted state becomes a restore, not a rebuild), a CMK with `bucket_key_enabled` (Terraform reads and writes state constantly; without bucket keys every operation is a separate KMS call), a policy denying non-TLS access, a lifecycle rule so versions do not accumulate forever, and `prevent_destroy` — one of the few places that flag genuinely earns its keep.
- **`use_lockfile = true`** — S3-native locking, Terraform 1.10+, no DynamoDB table. The migration trap: a **plan** needs `s3:PutObject` and `s3:DeleteObject` too, because the lock is an object written beside the state. The error (`Error acquiring the state lock`) does not mention S3 permissions.
- **GitHub OIDC** instead of an access key in a repository secret. Nothing to rotate and nothing to steal: the token is minted per job and lasts minutes. The condition people get wrong is `sub`: without it **any repository on GitHub** can assume the role, and with `repo:owner/name:*` any branch or fork pull request can. `github_subjects` is validated to reject a bare `*`, and the plan role gets read-only plus state access — so a pull-request pipeline can run on every push without being able to change anything.

## Cost, honestly

Nothing in this directory is applied by the checks: they are `validate`, `tflint`, `trivy` and mocked tests, all free. If you *do* apply it:

| | Roughly |
|---|---|
| `envs/bootstrap` | ~$1/month — the CMK; S3 at this size is pennies, IAM and OIDC are free |
| `envs/dev` as written | ~$60–90/month — the ALB is ~$16, `db.t4g.micro` Multi-AZ off is free-tier-eligible for 12 months, three Fargate tasks at 256/512 are a few dollars each, and a **NAT gateway is ~$32 plus data** unless the network root uses VPC endpoints |
| `envs/prod` as written | several hundred — Multi-AZ RDS on `db.t4g.medium`, 365-day log retention, larger tasks |

The NAT gateway is usually the surprise, and it belongs to the network root rather than this one. The module documents interface endpoints as the tighter (and cheaper) answer in `alb.tf`.

**Neither environment root is applied by any `make` target.** Applying costs money and touches a real account, so it stays a deliberate act: `cd envs/dev && terraform init && terraform plan`.

## Production mapping

| In this lab | In production |
|---|---|
| `mock_provider` apply tests on every commit | the same runs, plus a nightly apply/destroy into a sandbox account |
| network, certificate and log bucket as variables with lab defaults | `terraform_remote_state` data sources or SSM parameters written by the network and platform roots, so a plan cannot run against a VPC that does not exist |
| `source = "../../modules/app_stack"` | a pinned git tag; promotion is bumping the ref in `envs/prod` after it has soaked in dev |
| commented-out `backend "s3"` | uncommented, one key per root, prod state in a different account |
| commented-out `assume_role` | the OIDC role from `envs/bootstrap`, with plan and apply as separate roles |
| `terraform apply` by hand | apply of the **saved plan** on merge, with the prod job gated on a GitHub environment that pins the OIDC `sub` |
| `trivy` in `make check` | the same, plus OPA/conftest on the plan JSON for rules that need to see the diff rather than the code |
