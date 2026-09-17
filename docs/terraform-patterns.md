# Terraform patterns

Lab: [`labs/lab1-terraform`](../labs/lab1-terraform/).

## 1. Modules and roots

- **All logic in versioned modules; roots are thin.** A root sets the backend and provider configuration and passes inputs. `envs/dev` and `envs/prod` call the same module version with different `tfvars`.
- **No `provider` blocks inside modules**, only `required_providers` constraints. The caller configures region, credentials and assume-role.
- **Typed, validated inputs.** `object` with `optional()` attributes, never `any`. No default on required inputs, safe defaults on optional ones. `validation` blocks for single-variable rules; `precondition` for rules that need resource context (for example, prod requires ≥ 2 replicas).
- **Outputs are the interface**, shaped as maps keyed like the input.
- **Consumed at a pinned version** (`?ref=v1.4.0` or a registry version). Promotion = bump the ref after it has soaked.

## 2. Environments: directories, not workspaces

| | Directory per environment | Workspaces |
|---|---|---|
| State | separate file and backend key | separate state, **same backend and credentials** |
| Credentials | per-root role; dev CI can't assume prod | shared unless wrapped |
| Selecting the target | the path in the pipeline | a CLI setting in someone's terminal |
| Approval gates | per root | per pipeline convention |

Workspaces suit short-lived copies of one environment (feature stacks). Long-lived environments with different blast radii get directories.

## 3. `for_each`

The rules, each with a runnable example in `labs/lab1-terraform/examples/`:

1. **`for_each` for anything with an identity; `count` only for identical copies** and the `count = var.x ? 1 : 0` toggle. With `count`, removing element 0 re-indexes everything after it (example 01: 2 replaces + 1 destroy vs. exactly 1 destroy).
2. **The key is the design.** Derive it from the data's identity (`service-port`, `svc:port:cidr`), never from a list position. A positional key inside `for_each` reintroduces the bug (example 03: adding one CIDR *replaced* 4 rules).
3. **Keys must be known at plan time.** Key on names from configuration; put computed values in `each.value` (example 02, "Invalid for_each argument").
4. **Flatten nested data into one map with a composite key** (`flatten` + a `for` expression, or `setproduct`), and validate uniqueness before it becomes a "Duplicate object key".
5. **Filter with `if`** to make a resource conditional per key; an empty map means zero instances.
6. **Key dependencies like their consumers.** One shared value embedded in every instance re-couples what `for_each` separated: lab 1's module once replaced every service when one was removed.
7. **Refactor with `moved` blocks**, not `terraform state mv`. Example 04 migrates `count` → `for_each` with 3 moves and 0 changes, and the same object ids before and after.

## 4. State

- **Backend**: S3, one key per root, bucket **versioning on**, SSE-KMS with a dedicated key, public access blocked, TLS-only bucket policy, access through roles only. State buckets live in a **separate account** from workloads, so an over-broad workload role can't read state.
- **Locking**: `use_lockfile = true`, S3-native locking via conditional writes (Terraform 1.10+). It replaces `dynamodb_table`, which is deprecated from 1.11. Migrate by enabling both for one cycle, then removing the table.
- **State is sensitive data.** It holds database passwords and key material in plaintext regardless of how variables were marked. Encrypt it, access-log it, never commit it.
- **Stuck lock** after a killed CI run: read the lock (who, what operation, when), confirm that run is really gone, then `terraform force-unlock <LOCK_ID>`. Never force-unlock because a plan is waiting; if the apply is still running you get two writers on one state.

## 5. Review and promotion

```text
PR opened ─► fmt -check ─► validate ─► tflint ─► terraform test ─► security scan (checkov / trivy)
         ─► plan -out=tfplan ─► policy on plan JSON (OPA/conftest) ─► plan posted to the PR ─► review
merge    ─► apply tfplan (the SAVED plan, never a fresh one) ─► dev ─► staging ─► prod (approval + change window)
```

- **Apply the saved plan.** The reviewer approved a specific diff; re-planning at apply time can include changes no one reviewed.
- **Grep every prod plan for replacements** (`must be replaced`, `forces replacement`). A replacement in prod is its own deliberate change, never a side effect.
- **Policy on the plan JSON** enforces the rules that matter locally: no `0.0.0.0/0` on management ports, encryption required, mandatory tags, no destroy of protected types without an explicit label.

## 6. When an apply fails halfway

Terraform isn't transactional. Resources that succeeded are in state; one resource may exist but be **missing from state**. Work through diagnosis, then containment, then repair:

| Situation | Action |
|---|---|
| transient: throttling, eventual consistency, quota | fix the cause, re-apply. Terraform converges from state |
| created but half-configured | `terraform apply -replace=<address>` |
| exists in the cloud, missing from state | an **`import` block** (reviewed in the PR, visible in plan); never let the next apply create a duplicate |
| state corrupted or wrongly edited | restore the previous object version from the versioned bucket |
| lock left behind | confirm the run is dead, then `force-unlock` |

**Rollback** is re-applying the last known-good commit, almost never `terraform destroy`. The real protections come earlier: small blast-radius roots, stateful resources in their own roots with `prevent_destroy`, `create_before_destroy` where a replacement would cause an outage (only when the replacement gets a new name — on a fixed-name object the destroy deletes the replacement), and reading plans for *destroy* before approving them.

## 7. Testing

| Layer | Tool | In this repo |
|---|---|---|
| format, validity | `terraform fmt -check`, `validate` | CI |
| lint | `tflint` | CI, all roots clean |
| contract tests (plan-only) | `terraform test` with `expect_failures` | 12 runs, guard rails mutation-checked |
| integration tests (apply, read back, destroy) | `terraform test` with `command = apply`; Terratest in a sandbox account | 4 lifecycle runs: create, update one key, remove one key, replace; mutation-checked |
| post-apply verification of a live environment | a smoke stage after every apply: describe calls, target health, a request through each endpoint | `verify-env.py`: exists, integrity, unmanaged, wiring, policy, outputs; proven by `tamper-env.sh` |
| behaviour examples | `examples/*/demo.sh` | CI |
