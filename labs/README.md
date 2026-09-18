# labs/

Three self-contained labs, one per layer of an infrastructure platform. Everything runs on a laptop at **$0**: no cloud account, no credentials, no hardware — the AWS code included, because it is apply-tested against a mocked provider.

| Lab | Layer | Runs on | Headline results (all verified) |
|---|---|---|---|
| [`lab1-terraform/`](lab1-terraform/) | resources: does it exist, what is it attached to | Terraform only | 16 `terraform test` runs (12 plan, 4 apply); both envs applied, verified, tampered, remediated and destroyed; 4 `for_each` demos; drift exit 2 → 0 with the record kept |
| [`lab1-terraform/aws/`](lab1-terraform/aws/) | the same resources, on real AWS | Terraform + the `aws` provider | 22 runs (18 plan, 4 apply) against `mock_provider` in 2.7 s with no credentials; 11 mutations caught; `tflint` aws ruleset and `trivy` clean with 4 waivers reasoned in code |
| [`lab2-ansible/`](lab2-ansible/) | inside the machine | Ansible + Docker | idempotent role (0 changes on run 2, 6 hosts); 8 bad inputs rejected; rolling patch stops after 3 hosts; kernel tuning on **4 distributions** with 20 artifact assertions + 16 contract cases; `ansible-lint` production profile |
| [`lab3-baremetal/`](lab3-baremetal/) | the physical build, and its cloud twin | Python (+ Docker for real-parser checks) | two source-of-truth files → kickstarts, DHCP, cloud-init, Terraform input, Ansible inventory; 39 unit tests; `dhcpd -t`, `ksvalidator` and `cloud-init schema` pass |

## How they connect

```text
lab3: hosts.yml ──────► kickstart + DHCP ─────► out/inventory.yml ──┐
      cloud-hosts.yml ─► cloud-init + tfvars ──► lab1 ─► tags ──────┤
                                                                    ├─► lab2: baseline + kernel ─► drift-check.sh
lab1: Terraform ──────► instances + tags (aws_ec2 inventory) ───────┘

lab1: drift-check.sh (infrastructure layer)          lab2: drift-check.sh (OS layer)
```

The same `baseline` and `kernel` roles configure a server whether lab 3's pipeline built it, Terraform created it, or it is a container standing in for either. Drift is detected at both layers, with the same exit-code contract and the same immutable record format.

The join between the labs is a **tag set** — `Environment`, `Role`, `Service`, `ManagedBy`, `KernelProfile` — asserted on all three sides: `terraform test` checks the module stamps them, lab 3's unit tests check the rendered tags produce the groups the playbooks target, and lab 2's `group_vars` files are named after those groups. See [`docs/aws-platform.md`](../docs/aws-platform.md).

## Requirements

| Tool | Verified version | Needed by |
|---|---|---|
| Terraform | 1.16.1 (≥ 1.6, and ≥ 1.7 for the AWS module's `mock_provider`) | lab 1 |
| tflint, trivy | 0.61.0, 0.74.0 | `make check` only; the AWS roots also need `tflint --init` for the aws ruleset (the Makefile does it) |
| jq | 1.8 | lab 1 examples |
| ansible-core | 2.21.4 (≥ 2.15 required) | labs 2 and 3 |
| ansible-lint | 26.8.0 | `make check` only |
| Docker | 29.4 | lab 2 (six AlmaLinux hosts + four distribution hosts); lab 3 artifact checks |
| Python | 3.12+ (verified on 3.14) | labs 1, 2 and 3 scripts |

## Suggested order

1. **Lab 2**: the richest. Role design, idempotence, safe rollouts, drift. About 45 minutes — plus 25 for the `kernel` role across four distributions.
2. **Lab 1**: `for_each`, the module tests, and verifying live environments. About 50 minutes — then [`aws/`](lab1-terraform/aws/) for the real provider and what a mocked apply test can and cannot prove, about 30.
3. **Lab 3**: the build pipeline, its cloud twin, and their validation. About 30 minutes.

Or, from the repository root: `make ci` (about 20 seconds, no Docker), then `make all`.
