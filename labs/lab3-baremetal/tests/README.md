# tests/

```bash
python3 -m unittest discover -s tests -v      # from labs/lab3-baremetal
```

20 tests, standard library only. Each validator test copies a known-good record and breaks **exactly one thing**, so a failure points at one rule.

| Class | Tests |
|---|---|
| `SourceOfTruthIsValid` | the committed `hosts.yml` validates; the stdlib YAML fallback returns exactly what PyYAML returns |
| `ValidatorRejectsBadRecords` | missing field, duplicate MAC, duplicate IP, two servers in one rack unit, gateway outside subnet, broadcast address, VLAN out of range, single-member bond, uppercase MAC, unknown profile |
| `RendererProducesCompleteArtifacts` | no unrendered placeholders; identity and network in the kickstart; **no line continuations**; a missing value is a hard error; filename matches the iPXE request path; netmask from prefix; one DHCP reservation per host; every host handed to Ansible |

## Tests that were checked by mutation

- **Fallback reader.** The test swaps out the import machinery, so it could have passed without exercising the fallback. Removing the integer handling from the fallback made it fail.
- **Line continuations.** Wrapping the `network` line in the template made it fail.

The unit tests prove the renderer does what was intended; `../scripts/check_artifacts.sh` proves the intended output is valid to `dhcpd` and the installer. Both matter: the second found three bugs the first couldn't.
