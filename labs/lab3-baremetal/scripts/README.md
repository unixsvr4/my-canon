# scripts/

| Script | Runs | Purpose |
|---|---|---|
| `validate_hosts.py` | anywhere (Python 3 stdlib; PyYAML optional) | reject bad source-of-truth data, reporting every error at once |
| `render.py` | anywhere | validate, then generate `out/ks/<mac>.cfg`, `out/dhcpd-hosts.conf`, `out/inventory.yml` |
| `check_artifacts.sh` | Docker | validate generated artifacts with the real parsers: `dhcpd -t`, `ksvalidator` |
| `bmc_baseline.sh` | **reference only** | Redfish calls for inventory, firmware, BIOS-as-code, one-time PXE boot |

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

## `render.py` outputs

- **`out/ks/<mac>.cfg`**: named for iPXE's `${mac:hexhyp}`, so the boot script needs no per-host logic.
- **`out/dhcpd-hosts.conf`**: `host` reservations, included once at global scope by `ipxe/dhcpd.conf.snippet`.
- **`out/inventory.yml`**: the handoff. Groups: `rhel9`, `newly_built` (what `acceptance.yml` targets), one group per role (`gateway`, `database`) and per rack (`rack_dc1_r14`). `expected_ip` is carried for the acceptance assertions, so the build and its test share one source.

## `bmc_baseline.sh`

Points at a BMC that doesn't exist in this lab. Read it, don't run it. It shows the out-of-band sequence as API calls: identify the system, inventory firmware (drift between "identical" servers usually hides there), PATCH BIOS attributes from a template, set a one-time PXE boot and reset. That is "rebuild" as an API call, with credentials from a vault and never hard-coded.
