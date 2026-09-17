# kickstart/ — the unattended install

`rhel9-min.ks.j2` is rendered once per host by `../scripts/render.py` into `../out/ks/<mac>.cfg`. It uses `{{ key }}`
placeholders; a placeholder with no value in `hosts.yml` is a **hard error** naming the host and key, never an empty
string written into an answer file.

## Design: deliberately thin

The kickstart's only job is to produce a **reachable, minimal, correctly-addressed** machine and hand it to
configuration management. Everything that could differ between two servers belongs in Ansible, where it is versioned,
re-runnable and drift-checked. A `%post` block runs once and is never checked again.

| Section | Decision | Why |
|---|---|---|
| `network` | static, bond (802.3ad) + VLAN, from inventory, **on one line** | identity is data; kickstart has no `\` line continuation |
| disks | `clearpart --all`, explicit `/boot/efi`, `/boot`, LVM with sized `/`, `/var`, `/var/log`, swap | a rebuild must produce an identical layout; a full `/var/log` must not fill `/` |
| `bootloader --append` | serial console; `intel_idle.max_cstate=0 processor.max_cstate=1` | remote console access; C-state exit latency matters for latency-sensitive workloads |
| `rootpw --lock` | no interactive root | access is via the automation account and audited sudo |
| `selinux --enforcing`, `firewall --enabled` | secure by default | turning them on later is harder than never turning them off |
| `%packages` | `@^minimal-environment` + `chrony python3 sudo` | only what configuration management needs to take over (`--minimal` isn't a valid option) |
| `%post` | install the automation key, POST a registration callback | the callback makes a build that never finishes *visible* |

## Validate

```bash
../scripts/check_artifacts.sh    # ksvalidator -v RHEL9 on every rendered file
```
