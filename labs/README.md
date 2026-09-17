# labs/

Three self-contained labs, one per layer of an infrastructure platform. Everything runs on a laptop at **$0**: no
cloud account, no credentials, no hardware.

| Lab | Layer | Runs on | Headline results (all verified) |
|---|---|---|---|
| [`lab1-terraform/`](lab1-terraform/) | resources: does it exist, what is it attached to | Terraform only | 12 `terraform test` runs; 4 `for_each` demos; drift exit 2 → 0 with the record kept |
| [`lab2-ansible/`](lab2-ansible/) | inside the machine | Ansible + Docker | idempotent role (0 changes on run 2, 6 hosts); 8 bad inputs rejected; rolling patch stops after 3 hosts; `ansible-lint` production profile |
| [`lab3-baremetal/`](lab3-baremetal/) | the physical build | Python (+ Docker for real-parser checks) | one source of truth → kickstarts, DHCP, Ansible inventory; 20 unit tests; `dhcpd -t` and `ksvalidator` pass |

## How they connect

```text
lab3: hosts.yml ─► kickstart + DHCP ─► out/inventory.yml ──┐
                                                            ├─► lab2: roles/baseline ─► drift-check.sh
lab1: Terraform ─► instances + tags (dynamic inventory) ────┘
lab1: drift-check.sh (infrastructure layer)          lab2: drift-check.sh (OS layer)
```

The same `baseline` role configures a server whether lab 3's pipeline built it or Terraform created it. Drift is
detected at both layers, with the same exit-code contract and the same immutable record format.

## Requirements

| Tool | Verified version | Needed by |
|---|---|---|
| Terraform | 1.16.1 (≥ 1.6 required) | lab 1 |
| tflint, trivy | 0.61.0, 0.74.0 | `make check` only |
| jq | 1.8 | lab 1 examples |
| ansible-core | 2.21.4 (≥ 2.15 required) | labs 2 and 3 |
| ansible-lint | 26.8.0 | `make check` only |
| Docker | 29.4 | lab 2; lab 3 artifact checks |
| Python | 3.12+ (verified on 3.14) | labs 1, 2 and 3 scripts |

## Suggested order

1. **Lab 2**: the richest. Role design, idempotence, safe rollouts, drift. About 45 minutes.
2. **Lab 1**: `for_each` and the module tests. About 45 minutes.
3. **Lab 3**: the build pipeline and its validation. About 25 minutes.

Or, from the repository root: `make ci` (about 20 seconds, no Docker), then `make all`.
