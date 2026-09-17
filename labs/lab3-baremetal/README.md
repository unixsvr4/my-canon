# Lab 3 — Bare metal: from a MAC address to a production-ready server

A server factory is a pipeline in which **no build-day decision is made by a human at a console**. This lab holds the
artifacts of that pipeline: one source-of-truth file, the files generated from it, the network-boot configuration
that consumes them, and the tests that prove each one is valid.

No physical hardware is involved. The generated artifacts are checked by unit tests, and validated by the **same
parsers the real systems use**, ISC `dhcpd -t` and the installer's `ksvalidator`, in a throwaway container.

## The pipeline

```text
 hosts.yml ──validate──► render ──┬─► out/dhcpd-hosts.conf ──► DHCP: MAC gets a reservation + boot file
 (source of truth)                ├─► out/ks/<mac>.cfg ──────► iPXE fetches it by MAC ──► unattended install
                                  └─► out/inventory.yml ─────► Ansible: baseline role (Lab 2) ──► acceptance.yml
```

| Stage | What happens | Artifact | Automated? |
|---|---|---|---|
| 1. Rack & record | asset, serial, rack/U, MAC recorded **before power-on** | `hosts.yml` (CMDB/DCIM in production) | data entry, then validated |
| 2. Out-of-band first | BMC address + unique credentials, OOB VLAN | `scripts/bmc_baseline.sh` | yes (Redfish) |
| 3. Firmware & BIOS | approved firmware set, BIOS settings as code | `scripts/bmc_baseline.sh` | yes (Redfish) |
| 4. Network boot | DHCP → iPXE → per-MAC decision; unknown MACs refused | `ipxe/` | yes |
| 5. Unattended install | per-host kickstart: disks, bond, VLAN, locked root | `kickstart/` → `out/ks/` | yes |
| 6. Handoff | host enters configuration management as data | `out/inventory.yml` | yes |
| 7. Configure | the same baseline role used for every other host | `../lab2-ansible/roles/baseline` | yes |
| 8. Accept | "production-ready" as assertions, on every build | `acceptance.yml` | yes |
| 9. Enter production | monitoring, backups, patch group, then the load balancer | — | gated |

## Layout

```text
lab3-baremetal/
├── hosts.yml                  # the source of truth: 3 servers, 2 VLANs, 2 racks
├── scripts/
│   ├── validate_hosts.py      # refuse bad data: duplicates, wrong subnet, bad VLAN, 1-member bond
│   ├── render.py              # generate kickstarts, DHCP reservations, Ansible inventory
│   ├── check_artifacts.sh     # dhcpd -t + ksvalidator, with the real tools, in a container
│   └── bmc_baseline.sh        # Redfish: inventory, firmware, BIOS-as-code, one-time PXE (reference)
├── ipxe/                      # dhcpd.conf snippet + boot.ipxe
├── kickstart/                 # the RHEL 9 template
├── acceptance.yml             # post-build assertions against the generated inventory
├── tests/                     # 20 stdlib unit tests
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

The kickstart filename **is** the MAC, which is exactly the path `ipxe/boot.ipxe` requests (`ks/${mac:hexhyp}.cfg`).
A unit test pins that contract.

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

Every error is reported at once, and nothing is rendered. Two servers answering to one MAC, or a database whose
gateway is on another subnet, is the kind of mistake that otherwise turns up at 3 a.m., on a console, in a data
centre nobody can get into.

### Tests

```bash
python3 -m unittest discover -s tests -v
```

20 tests: the committed `hosts.yml` is valid; the validator rejects ten kinds of bad record; rendered artifacts have no
unrendered placeholders, carry the right identity and network, and match the iPXE request path; the stdlib YAML
fallback matches PyYAML. See [`tests/README.md`](tests/README.md).

### Validate with the real parsers

```bash
./scripts/check_artifacts.sh
```

```text
PASS  dhcpd -t: snippet + generated reservations
PASS  ksvalidator RHEL9: 3c-ec-ef-11-22-33.cfg
PASS  ksvalidator RHEL9: 3c-ec-ef-11-22-34.cfg
PASS  ksvalidator RHEL9: 3c-ec-ef-11-23-01.cfg
```

This check exists because unit tests only prove the renderer does what was *intended*. When first run, it found three
bugs that no unit test could see:

| Found by | Bug | Effect on a real build |
|---|---|---|
| `dhcpd -t` | branching on `option architecture-type`, a name ISC dhcpd doesn't define | DHCP server refuses to start |
| `ksvalidator` | the `network` command wrapped across lines with `\` — kickstart has no line continuation | bond, IP and VLAN silently never configured |
| `ksvalidator` | `%packages --minimal` — not a valid option | installer rejects the kickstart |

Each fix carries a comment, and the line-continuation case also has a unit test, so it fails without Docker too.

## What in these files shows operational experience

1. **`boot.ipxe` refuses to build an unregistered MAC.** Anything not in the source of truth gets a message, not an
   operating system. That single rule prevents orphan servers.
2. **The DHCP config tests the iPXE user-class.** Without it the chainload loops forever: the NIC ROM loads iPXE, iPXE
   asks DHCP again, gets iPXE again, and so on.
3. **iPXE fetches over HTTP, not TFTP.** TFTP has no windowing and stalls on congested or high-latency links; a large
   initrd over TFTP is how builds hang at 47%.
4. **The kickstart pins the disk layout explicitly** (`clearpart --all`, explicit LVs), so a rebuild produces an
   identical layout. Twin servers must actually be twins.
5. **C-state limits are in the bootloader line.** For latency-sensitive workloads, deep C-state exit latency is part of
   the build standard, not something someone remembers to set afterwards.
6. **`%post` does almost nothing.** It installs a key and calls a registration endpoint. Everything else is Ansible,
   because a `%post` block runs once and is invisible drift forever after.
7. **Acceptance is part of the build.** A build isn't done when the installer finishes; it is done when
   `acceptance.yml` passes: kernel, identity, disk layout, bond members up, NTP synchronised, agents running, required
   endpoints reachable.

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

If the DHCP server never saw the request, the problem is the switch port, the VLAN or the helper address. If it did,
the problem is downstream.

## Production tooling

The same primitives sit under the products: **Foreman/Katello** or **MAAS** for lifecycle and templated provisioning,
**OpenStack Ironic** or **Tinkerbell** for API-driven bare metal, **NetBox/Nautobot** as the source of truth, and
**Redfish** as the vendor-neutral out-of-band API. DHCP, a bootloader, an answer file and configuration management are
underneath all of them, which is why understanding this pipeline transfers to whichever product fronts it.
