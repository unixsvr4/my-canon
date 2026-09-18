# Lab 3 — Bare metal and EC2: from a MAC address (or an API call) to a production-ready server

A server factory is a pipeline in which **no build-day decision is made by a human at a console**. This lab holds the artifacts of that pipeline: one source-of-truth file, the files generated from it, the network-boot configuration that consumes them, and the tests that prove each one is valid.

No physical hardware is involved. The generated artifacts are checked by 39 unit tests, and validated by the **same parsers the real systems use** — ISC `dhcpd -t`, the installer's `ksvalidator`, and `cloud-init schema` — in a throwaway container.

The lab has two halves, because a real platform does. `hosts.yml` describes machines that must be **built**: they have a MAC address, a rack, a unit, a disk to partition and a bond to configure. `cloud-hosts.yml` describes machines that are **declared**: an EC2 instance exists as soon as the API call returns. The fields differ, and that is the honest shape of a hybrid fleet — one CMDB, two record types. What they share is everything downstream: the same renderer, the same Ansible groups, and the same `baseline` and `kernel` roles from lab 2. **Configuration management sees one fleet.**

## The pipeline

```text
 hosts.yml ──validate──► render ──┬─► out/dhcpd-hosts.conf ──► DHCP: MAC gets a reservation + boot file
 (physical)                       ├─► out/ks/<mac>.cfg ──────► iPXE fetches it by MAC ──► unattended install
                                  └─► out/inventory.yml ──┐
                                                          ├──► Ansible: baseline + kernel (Lab 2) ──► acceptance.yml
 cloud-hosts.yml ─validate─► render ─┬─► out/cloud-init/<host>.yaml ──► EC2 user data, first boot
 (declared)                          ├─► out/aws/instances.auto.tfvars.json ──► Terraform (Lab 1) ──► tagged instances
                                     └─► out/aws/inventory-preview.yml ──┘   (the tags ARE the inventory)
```

Nothing is rendered if **either** record set is invalid. Rendering the valid half would leave `out/` holding a mix of current and stale artifacts, which is harder to debug than no artifacts at all.

| Stage | What happens | Artifact | Automated? |
|---|---|---|---|
| 1. Rack & record | asset, serial, rack/U, MAC recorded **before power-on** | `hosts.yml` (CMDB/DCIM in production) | data entry, then validated |
| 2. Out-of-band first | BMC address + unique credentials, OOB VLAN | `scripts/bmc_baseline.sh` | yes (Redfish) |
| 3. Firmware & BIOS | approved firmware set, BIOS settings as code | `scripts/bmc_baseline.sh` | yes (Redfish) |
| 4. Network boot | DHCP → iPXE → per-MAC decision; unknown MACs refused | `ipxe/` | yes |
| 5. Unattended install | per-host kickstart: disks, bond, VLAN, locked root | `kickstart/` → `out/ks/` | yes |
| 6. Handoff | host enters configuration management as data | `out/inventory.yml` | yes |
| 7. Configure | the same baseline and kernel roles every other host gets | `../lab2-ansible/roles/` | yes |
| 8. Accept | "production-ready" as assertions, on every build | `acceptance.yml` | yes |
| 9. Enter production | monitoring, backups, patch group, then the load balancer | — | gated |

## Layout

```text
lab3-baremetal/
├── hosts.yml                  # physical: 3 servers, 2 VLANs, 2 racks
├── cloud-hosts.yml            # declared: 3 EC2 instances, 2 availability zones
├── scripts/
│   ├── validate_hosts.py      # refuse bad data: duplicates, wrong subnet, bad VLAN, 1-member bond
│   ├── render.py              # generate kickstarts, DHCP reservations, Ansible inventory
│   ├── check_artifacts.sh     # dhcpd -t + ksvalidator + cloud-init schema, in a container
│   ├── bmc_baseline.sh        # Redfish: inventory, firmware, BIOS-as-code, one-time PXE (reference)
│   └── ssm_hybrid_register.sh # register a PHYSICAL server into AWS Systems Manager (reference)
├── ipxe/                      # dhcpd.conf snippet + boot.ipxe
├── kickstart/                 # the RHEL 9 template
├── acceptance.yml             # post-build assertions against the generated inventory
├── tests/                     # 39 stdlib unit tests
├── windows/                   # the same pipeline with Microsoft tooling in each slot
└── out/                       # generated, gitignored - never edited by hand
```

## Run it

**All commands run from `labs/lab3-baremetal/`.** Python 3 is required; PyYAML is optional.

```bash
./scripts/render.py
```

```text
canon-gw01   3c:ec:ef:11:22:33  ->  out/ks/3c-ec-ef-11-22-33.cfg
canon-gw02   3c:ec:ef:11:22:34  ->  out/ks/3c-ec-ef-11-22-34.cfg
canon-db01   3c:ec:ef:11:23:01  ->  out/ks/3c-ec-ef-11-23-01.cfg
             3 reservation(s)  ->  out/dhcpd-hosts.conf
             ansible handoff    ->  out/inventory.yml
```

The kickstart filename **is** the MAC, which is exactly the path `ipxe/boot.ipxe` requests (`ks/${mac:hexhyp}.cfg`). A unit test pins that contract.

### Bad data never reaches a build

Simulate the most common real mistake, a record copy-pasted and only half edited:

```bash
cp hosts.yml /tmp/hosts.bak && sed -i.x 's/3c:ec:ef:11:22:34/3c:ec:ef:11:22:33/; s/gateway: 10.20.5.1/gateway: 10.20.4.1/' hosts.yml && ./scripts/render.py; mv /tmp/hosts.bak hosts.yml; rm -f hosts.yml.x
```

```text
refusing to render: hosts.yml has 2 error(s)
  - canon-gw02: duplicate mac 3c:ec:ef:11:22:33 (also used by canon-gw01)
  - canon-db01: gateway 10.20.4.1 is not in 10.20.5.0/24 - the host could never reach it
```

Every error is reported at once, and nothing is rendered. Two servers answering to one MAC, or a database whose gateway is on another subnet, is the kind of mistake that otherwise turns up at 3 a.m., on a console, in a data centre nobody can get into.

### Tests

```bash
python3 -m unittest discover -s tests -v
```

39 tests: both committed record sets are valid; the validators reject ten kinds of bad physical record and eleven kinds of bad cloud record; rendered artifacts have no unrendered placeholders, carry the right identity and network, and match the iPXE request path; the stdlib YAML fallback matches PyYAML; and the tag contract produces the groups the playbooks target. See [`tests/README.md`](tests/README.md).

### Validate with the real parsers

```bash
./scripts/check_artifacts.sh
```

```text
PASS  dhcpd -t: snippet + generated reservations
PASS  ksvalidator RHEL9: 3c-ec-ef-11-22-33.cfg
PASS  ksvalidator RHEL9: 3c-ec-ef-11-22-34.cfg
PASS  ksvalidator RHEL9: 3c-ec-ef-11-23-01.cfg
PASS  cloud-init schema: canon-api01.yaml
PASS  cloud-init schema: canon-api02.yaml
PASS  cloud-init schema: canon-pg01.yaml
```

This check exists because unit tests only prove the renderer does what was *intended*. When first run, it found three bugs that no unit test could see:

| Found by | Bug | Effect on a real build |
|---|---|---|
| `dhcpd -t` | branching on `option architecture-type`, a name ISC dhcpd doesn't define | DHCP server refuses to start |
| `ksvalidator` | the `network` command wrapped across lines with `\` — kickstart has no line continuation | bond, IP and VLAN silently never configured |
| `ksvalidator` | `%packages --minimal` — not a valid option | installer rejects the kickstart |

Each fix carries a comment, and the line-continuation case also has a unit test, so it fails without Docker too.

`cloud-init schema` is there for the same reason, and it catches something a YAML test cannot: user data can be perfectly valid YAML and still be rejected or silently ignored, because the keys and their types are a schema. Both failure modes were checked by deliberately breaking a rendered file — an unknown key (`package_updates` for `package_update`) and a missing `#cloud-config` first line — and the validator rejected each. Without that first line, cloud-init treats the file as a shell script and **the whole thing is silently ignored**: the instance boots, passes its health check, and ran none of its configuration.

## The cloud half

```bash
./scripts/render.py
```

```text
canon-api01  m7g.large           ->  out/cloud-init/canon-api01.yaml
canon-api02  m7g.large           ->  out/cloud-init/canon-api02.yaml
canon-pg01   r7g.xlarge          ->  out/cloud-init/canon-pg01.yaml
             3 instance(s)     ->  out/aws/instances.auto.tfvars.json
             tag contract       ->  out/aws/inventory-preview.yml
```

### User data is the cloud's `%post`, and gets the same treatment

The kickstart's `%post` section installs a key and calls a registration endpoint, and nothing else, because a `%post` block runs once and is invisible drift forever after. **EC2 user data is exactly the same thing**, so it gets exactly the same discipline: hostname, the SSM agent, an identity file for the acceptance test, and then hand the host to Ansible.

Two details in the rendered file are there because their absence is a real incident:

- **`preserve_hostname: false` with an explicit `hostname`.** Without it, cloud-init rewrites the hostname from the private DNS name on **every boot**, the inventory name stops matching the host, and `patch.yml`'s pre-flight assertion fails — which is the good outcome; the bad one is every per-host record silently referring to a name that no longer exists.
- **`package_upgrade: false`.** Tempting, and it makes every instance in an Auto Scaling group a different machine depending on the minute it launched. Patching is a deliberate, batched operation with a health gate: that is `patch.yml`'s job, and it is the same reason lab 2's `baseline` role installs `state: present` and never `latest`.

### The tag contract, tested offline

`out/aws/instances.auto.tfvars.json` is a **map keyed by hostname** — the same reason lab 1's module takes a map rather than a list: removing one instance must destroy that one instance, not renumber the others and replace everything after it.

The tags in it are the handoff. Lab 1's Terraform stamps `Environment`, `Role`, `Service`, `ManagedBy` and `KernelProfile`; lab 2's [`aws_ec2` inventory](../lab2-ansible/inventory/aws_ec2.yml) turns them into groups; the playbooks target those groups by name. Nothing checks that link — so a typo in a tag value means `--limit tag_Role_database` matches nothing, the play reports **"no hosts matched" and exits 0**, and a rollout that touched zero hosts looks exactly like success.

So the renderer emits the groups those tags *will* produce:

```text
    tag_Role_database:
      hosts:
        canon-pg01: {}
    az_us_east_1a:
      hosts:
        canon-api01: {}
        canon-pg01: {}
```

It is not an inventory to run against — the real one comes from the EC2 API. It exists so the contract between all three labs is reviewable in a pull request and testable with **no AWS account**, which is what `test_tag_contract_produces_the_groups_the_playbooks_target` does.

### One control plane for both halves

The obvious objection to lab 2 reaching EC2 instances over Session Manager is that it only works for machines AWS created. It does not: a **hybrid activation** registers anything that can reach the SSM endpoints — a server in a rack, a VM in vSphere, a machine in another cloud. Registered hosts get an `mi-` id instead of `i-` and are otherwise ordinary managed instances, so SSM Inventory and Patch Manager cover them too.

```bash
./scripts/ssm_hybrid_register.sh canon-gw01
```

That means one access path, one IAM policy and one CloudTrail record set for a data-centre server and a VPC instance — with **no inbound firewall rule** in the data centre, because the agent polls outbound.

The script refuses a hostname that is not in `hosts.yml`, for the same reason `boot.ipxe` refuses an unregistered MAC: a managed instance nobody recorded is an orphan, and the console is where you find out.

```text
[ERROR] canon-ghost01 is not in hosts.yml.
        Add the record first: a host that is not in the source of truth
        must not be registered, or it becomes a managed instance with no owner.
```

It also treats the activation code as what it is — a credential valid for every registration until it expires — so it prints one for immediate use with a 24-hour expiry and a registration limit of 1, rather than storing it anywhere.

## What in these files shows operational experience

1. **`boot.ipxe` refuses to build an unregistered MAC.** Anything not in the source of truth gets a message, not an operating system. That single rule prevents orphan servers.
2. **The DHCP config tests the iPXE user-class.** Without it the chainload loops forever: the NIC ROM loads iPXE, iPXE asks DHCP again, gets iPXE again, and so on.
3. **iPXE fetches over HTTP, not TFTP.** TFTP has no windowing and stalls on congested or high-latency links; a large initrd over TFTP is how builds hang at 47%.
4. **The kickstart pins the disk layout explicitly** (`clearpart --all`, explicit LVs), so a rebuild produces an identical layout. Twin servers must actually be twins.
5. **C-state limits are in the bootloader line.** For latency-sensitive workloads, deep C-state exit latency is part of the build standard, not something someone remembers to set afterwards.
6. **`%post` does almost nothing.** It installs a key and calls a registration endpoint. Everything else is Ansible, because a `%post` block runs once and is invisible drift forever after.
7. **The validators check the FLEET, not just the record.** Three rules catch mistakes that pass record-by-record review: a hostname that collides across the two files (which caught a real collision in the very fixture added for it), a prod service with every instance in one availability zone, and a database on an instance family with no memory advantage. A copy-pasted record where only the name was changed is individually valid and collectively an outage.
8. **Acceptance is part of the build.** A build isn't done when the installer finishes; it is done when `acceptance.yml` passes: kernel, identity, disk layout, bond members up, NTP synchronised, agents running, required endpoints reachable.

## Debugging a failed build, bottom-up

Work in dependency order, and read each stage's log before touching the next:

| Symptom | Where the problem usually is | Where to look |
|---|---|---|
| no PXE attempt | boot order, PXE disabled on that NIC, cabled to the wrong NIC | BMC console, BIOS settings via Redfish |
| `DHCP....` then nothing | no reservation for this MAC; no `ip helper-address` on the VLAN; a rogue DHCP server | DHCP server log — did the DISCOVER arrive at all? |
| DHCP OK, boot file never loads | wrong `next-server`/`filename`, blocked TFTP/HTTP, MTU | HTTP access log |
| wrong loader, or boots then halts | UEFI vs BIOS mismatch; Secure Boot needs the signed shim | DHCP option 93 in the request |
| installer starts, then dies | kickstart syntax, unreachable repo, disk names that differ from the template | `/tmp/anaconda.log` on the console, `ksvalidator` beforehand |
| installed, no network | NIC renamed, driver missing from initrd, switch port in the wrong VLAN, bond mode mismatch with the switch | `/proc/net/bonding/bond0`, switch LACP state |
| builds fine, behaves unlike its twin | firmware or BIOS drift | Redfish firmware inventory diff |
| everything works, nothing monitors it | handoff/registration failed silently | the registration callback log; `acceptance.yml` |

If the DHCP server never saw the request, the problem is the switch port, the VLAN or the helper address. If it did, the problem is downstream.

## Production tooling

The same primitives sit under the products: **Foreman/Katello** or **MAAS** for lifecycle and templated provisioning, **OpenStack Ironic** or **Tinkerbell** for API-driven bare metal, **NetBox/Nautobot** as the source of truth, and **Redfish** as the vendor-neutral out-of-band API. DHCP, a bootloader, an answer file and configuration management are underneath all of them, which is why understanding this pipeline transfers to whichever product fronts it.
