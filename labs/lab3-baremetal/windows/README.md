# Windows: the same build pipeline, Microsoft tooling in each slot

The Linux pipeline in this lab (source of truth → network boot → unattended install → configuration management →
acceptance) maps stage for stage onto Windows. The design decisions carry over; only the tools change.

| Stage | Linux (this lab) | Windows |
|---|---|---|
| Source of truth | `hosts.yml` → rendered artifacts | the same record, rendering an answer file per host |
| Network boot | PXE / iPXE + DHCP + HTTP | WDS (PXE), or MDT / Configuration Manager boot media |
| Answer file | kickstart | `Autounattend.xml` |
| Image | minimal package set from a pinned repo | a reference `.wim`, captured and versioned |
| Drivers | in the initrd / driver update disk | driver packs injected per hardware model — the stage that breaks most often |
| Identity | static network config from inventory | domain join in the answer file or a first-boot task |
| Post-build config | Ansible roles over SSH | Ansible `ansible.windows` / `community.windows` modules over WinRM, and/or DSC |
| Drift detection | `ansible-playbook --check --diff` | `Test-DscConfiguration`, or Ansible check mode |
| Patching | `dnf`, batched with `serial` | `win_updates` + `win_reboot`, batched — reboots are required far more often, so batches are smaller |

## Details that matter in practice

- **WinRM over HTTPS (5986) with Kerberos.** Not Basic. Avoid **CredSSP** unless there is no alternative: it relies
  on unconstrained credential delegation, and because it is NTLM-backed it isn't an option under FIPS.
- **The double-hop problem.** A task on host A that must reach a network resource B fails, because the credential
  used to reach A can't be delegated onward. Solve it with Kerberos constrained delegation, or by giving the task a
  credential it can use locally (`become` with `runas`).
- **DSC and Ansible are complementary.** DSC is the native desired-state engine and gives `Test-DscConfiguration` for
  free; call good existing DSC resources through `win_dsc` instead of re-implementing them. Ansible adds one
  inventory, one set of roles and one report across both halves of the estate.
- **Keep `Autounattend.xml` thin**, like the kickstart: generate it per host from the source of truth, and hand off
  to configuration management as early as possible. Anything configured in the answer file is configured once and
  never checked again.
