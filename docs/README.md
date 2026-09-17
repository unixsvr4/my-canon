# docs/

Design notes behind the labs. Each document explains the **why**, and links to the lab file that demonstrates it.

| Document | Covers | Demonstrated in |
|---|---|---|
| [`architecture.md`](architecture.md) | the end-to-end model: which tool owns which layer, and the handoffs | all three labs |
| [`terraform-patterns.md`](terraform-patterns.md) | modules, environments, `for_each`, state and locking, review pipeline, failure recovery | `labs/lab1-terraform` |
| [`ansible-patterns.md`](ansible-patterns.md) | reusable roles, idempotence, inventories, secrets, testing layers, rolling changes, patching at scale | `labs/lab2-ansible` |
| [`bare-metal-lifecycle.md`](bare-metal-lifecycle.md) | rack to production to decommission | `labs/lab3-baremetal` |
| [`drift-detection.md`](drift-detection.md) | drift at the infrastructure and OS layers: signals, exit codes, records, remediation policy | `drift-check.sh` in labs 1 and 2 |
| [`platform-translation.md`](platform-translation.md) | Spacelift, Alibaba Cloud, VMware vSphere and Windows mapped onto these patterns | — |
