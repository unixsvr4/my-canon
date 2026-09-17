# Bare-metal lifecycle: rack to production to decommission

Lab: [`labs/lab3-baremetal`](../labs/lab3-baremetal/). The lab README covers the artifacts, the generated handoff and the failure-mode table; this document covers the lifecycle and the reasoning.

## Principles

1. **The record exists before the power cord goes in.** Rack, U, serial, MACs and BMC address are entered into the CMDB/DCIM at racking. A server that isn't in the source of truth at racking tends to become an orphan.
2. **Out-of-band first.** Once the BMC is reachable with unique credentials on an isolated OOB network, nobody needs to be in the building again.
3. **Nothing decided at a console.** Firmware, BIOS, RAID, addressing and install profile all come from data.
4. **Keep the OS install thin.** The installer produces a reachable machine and hands it to configuration management. Configuration applied during install runs once and is never checked again.
5. **"Installer finished" isn't "done".** Acceptance tests decide.
6. **A rebuild is cheap.** A broken server gets rebuilt from PXE rather than repaired by hand, so every server stays reproducible.

## Stages

| # | Stage | Key decisions | Typical failure |
|---|---|---|---|
| 1 | Receive & rack | CMDB record first; cabling recorded | server racked, never recorded |
| 2 | OOB management | dedicated OOB VLAN, no route to production, per-host credentials from a vault, Redfish enabled | default BMC credentials left in place |
| 3 | Firmware & BIOS | approved firmware set; BIOS as code via Redfish: UEFI, PXE on the provisioning NIC, power profile, C-states, SR-IOV, NUMA | "identical" servers with different firmware |
| 4 | Storage | RAID profile per role, applied through the same OOB path | hand-built arrays that differ per host |
| 5 | Network boot | DHCP reservation per MAC; iPXE over HTTP; unknown MACs refused | missing helper address; TFTP stalls; UEFI/BIOS loader mismatch |
| 6 | Unattended install | per-host kickstart from data; explicit disk layout; bond + VLAN; locked root; thin `%post` | wrapped kickstart lines; NIC renamed on new hardware |
| 7 | Handoff | generated inventory; registration callback | the silent failure where the host installs but never registers |
| 8 | Configure | the same baseline and hardening roles as every other host, then role-specific ones | per-host snowflakes |
| 9 | Accept | kernel, identity, disk layout, bond members, NTP, agents, reachability; burn-in on new hardware | DOA memory or disk found by production traffic |
| 10 | Enter production | monitoring confirmed, backups registered, patch group + window, CMDB state live, **then** the load balancer | traffic before monitoring |
| 11 | Operate | patch cycles, firmware campaigns, drift detection, hardware replacement | firmware never updated after build |
| 12 | Decommission | wipe to policy; remove from inventory, monitoring, DNS, backups, DHCP; CMDB state retired | unpatched "ghost" servers still answering on the network |

## Latency-sensitive builds

For workloads where microseconds matter, some settings are part of the **build standard** rather than tuning applied later: a performance power profile, deep C-states disabled (in BIOS and on the kernel command line), deliberate hyper-threading and NUMA choices, and NIC firmware pinned. Encoding them in the Redfish template and the kickstart means every rebuild gets them.

## Tooling

| Need | Common choices |
|---|---|
| source of truth | NetBox, Nautobot, vendor DCIM |
| lifecycle + templated provisioning | Foreman/Katello, MAAS |
| API-driven bare metal | OpenStack Ironic, Tinkerbell |
| out-of-band | Redfish (vendor-neutral), `racadm`, iLO REST |
| Windows imaging | WDS/MDT or Configuration Manager + `Autounattend.xml` (see `labs/lab3-baremetal/windows/`) |

Under every product sit the same primitives: a source of truth, DHCP, a bootloader, an answer file and configuration management. That is why this pipeline's design transfers to whichever product fronts it.
