# scripts/

| Script | Runs | Purpose |
|---|---|---|
| `validate_hosts.py` | anywhere (Python 3 stdlib; PyYAML optional) | reject bad data in **both** record sets, reporting every error at once |
| `render.py` | anywhere | validate, then generate the physical artifacts and the cloud ones |
| `check_artifacts.sh` | Docker | validate generated artifacts with the real parsers: `dhcpd -t`, `ksvalidator`, `cloud-init schema` |
| `bmc_baseline.sh` | **reference only** | Redfish calls for inventory, firmware, BIOS-as-code, one-time PXE boot |
| `ssm_hybrid_register.sh` | **reference only** | register a physical server into AWS Systems Manager, so one control plane covers bare metal and EC2 |

## `validate_hosts.py` rules

| Rule | The mistake it catches |
|---|---|
| all required fields present | a half-filled record |
| hostname, MAC, IP, rack/U unique | a copy-pasted record; two servers claiming one rack unit |
| lowercase colon-separated MAC | the same MAC written two ways, so it is "unique" twice |
| gateway inside the host's subnet | a host that can never reach its gateway |
| IP isn't the network, broadcast or gateway address | an address that can't be assigned |
| VLAN 1–4094 | a typo'd VLAN that the switch silently rejects |
| bond has ≥ 2 members | a "redundant" link with one member |
| disk is a `/dev` path, profile is known | a template rendering against the wrong device or a profile that doesn't exist |

## `validate_hosts.py` cloud rules

The same principle, different fields — and three rules that are about the **fleet** rather than the record, because those are the mistakes that pass record-by-record review:

| Rule | The mistake it catches |
|---|---|
| hostname unique **across both files** | the same name on a physical server and an instance. It caught a real collision the first time it ran, in the fixture added for it |
| a prod service is not entirely in one AZ | a record copied for capacity where nobody changed the zone: every instance valid, the service with no availability story |
| a database is on a memory-optimised family | `m7g` where `r7g` was meant — a deliberate choice if you make it, a copy-paste if you do not |
| availability zone has its zone letter | `us-east-1` is a region; the API rejects it at apply time |
| instance type exists | `m7g.humongous` fails twenty minutes into an apply |
| `kernel_profile` is one lab 2's role knows | otherwise that role's `argument_specs` rejects it at converge time, later and further away |
| root volume ≥ 8 GiB, and ≥ 100 for a database | an instance that launches and fills during its first patch run |

## `render.py` outputs

Physical, from `hosts.yml`:

- **`out/ks/<mac>.cfg`**: named for iPXE's `${mac:hexhyp}`, so the boot script needs no per-host logic.
- **`out/dhcpd-hosts.conf`**: `host` reservations, included once at global scope by `ipxe/dhcpd.conf.snippet`.
- **`out/inventory.yml`**: the handoff. Groups: `rhel9`, `newly_built` (what `acceptance.yml` targets), one group per role (`gateway`, `database`) and per rack (`rack_dc1_r14`). `expected_ip` is carried for the acceptance assertions, so the build and its test share one source.

Cloud, from `cloud-hosts.yml`:

- **`out/cloud-init/<hostname>.yaml`**: EC2 user data — the cloud's `%post`, and treated with the same suspicion. It sets the hostname permanently (`preserve_hostname: false`, or cloud-init rewrites it from the private DNS name on every boot and the inventory name stops matching), installs and enables the SSM agent, writes an identity file for the acceptance test, and **does not upgrade packages**, because that would make every instance in an Auto Scaling group a different machine depending on the minute it launched.
- **`out/aws/instances.auto.tfvars.json`**: input to the Terraform root that creates them. A **map keyed by hostname**, for the same reason lab 1's module takes a map: removing one instance must destroy that one instance.
- **`out/aws/inventory-preview.yml`**: the Ansible groups those tags *will* produce. Not an inventory to run against — the real one comes from the EC2 API — but it makes the Terraform-to-Ansible tag contract reviewable in a pull request and testable with no AWS account.

Nothing is rendered if **either** record set is invalid: a mix of current and stale artifacts in `out/` is harder to debug than none.

## `bmc_baseline.sh`

Points at a BMC that doesn't exist in this lab. Read it, don't run it. It shows the out-of-band sequence as API calls: identify the system, inventory firmware (drift between "identical" servers usually hides there), PATCH BIOS attributes from a template, set a one-time PXE boot and reset. That is "rebuild" as an API call, with credentials from a vault and never hard-coded.

## `ssm_hybrid_register.sh`

A hybrid activation registers anything that can reach the SSM endpoints — a server in a rack, a VM in vSphere, a machine in another cloud — as a managed instance with an `mi-` id. That gives the physical half of the fleet the same access path, the same IAM policy and the same CloudTrail records as the EC2 half, with **no inbound firewall rule** in the data centre, because the agent polls outbound.

Two things the script is careful about:

- **It refuses a hostname that is not in `hosts.yml`**, for the same reason `ipxe/boot.ipxe` refuses an unregistered MAC. A managed instance nobody recorded is an orphan, and the SSM console is where you find out.
- **An activation code is a credential**, valid for every registration until it expires. So: a 24-hour expiry, a registration limit of 1, printed for immediate use and stored nowhere. A code left in a kickstart `%post` that stays on disk is a standing invitation to register a machine into your account.
