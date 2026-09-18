# tests/

```bash
python3 -m unittest discover -s tests -v      # from labs/lab3-baremetal
```

39 tests, standard library only. Each validator test copies a known-good record and breaks **exactly one thing**, so a failure points at one rule.

| Class | Tests |
|---|---|
| `SourceOfTruthIsValid` | the committed `hosts.yml` validates; the stdlib YAML fallback returns exactly what PyYAML returns |
| `ValidatorRejectsBadRecords` | missing field, duplicate MAC, duplicate IP, two servers in one rack unit, gateway outside subnet, broadcast address, VLAN out of range, single-member bond, uppercase MAC, unknown profile |
| `RendererProducesCompleteArtifacts` | no unrendered placeholders; identity and network in the kickstart; **no line continuations**; a missing value is a hard error; filename matches the iPXE request path; netmask from prefix; one DHCP reservation per host; every host handed to Ansible |
| `CloudSourceOfTruthIsValid` | the committed `cloud-hosts.yml` validates against the physical records too |
| `CloudValidatorRejectsBadRecords` | missing field; a **region where an AZ belongs** (`us-east-1` instead of `us-east-1a`); an instance type that does not exist; a hostname colliding with a physical host; a duplicate cloud hostname; an unknown `kernel_profile` (the contract with lab 2's role); an unknown environment; a root volume below the AMI minimum; a database with a volume that will fill; a database on a non-memory-optimised family; **a prod service entirely in one availability zone** |
| `CloudRendererProducesUsableArtifacts` | user data starts with `#cloud-config`; it is valid YAML and sets identity; it never upgrades packages on first boot; every host gets the mandatory tags; the tfvars is a **map keyed by hostname**; `volume_size` is a number and not a string; and **the tag contract produces the groups the playbooks target** |

## Tests that were checked by mutation

- **Fallback reader.** The test swaps out the import machinery, so it could have passed without exercising the fallback. Removing the integer handling from the fallback made it fail.
- **Line continuations.** Wrapping the `network` line in the template made it fail.
- **The cloud-init schema gate.** Two deliberate breaks to a rendered file — an unknown key (`package_updates` for `package_update`) and a missing `#cloud-config` first line — were each rejected by `cloud-init schema`, so the check is not passing vacuously.
- **The cross-file hostname rule** caught a real collision the first time it ran: `canon-db01` existed in both record sets, in the fixture added for the rule. That is the rule earning its keep before it was ever committed.

The unit tests prove the renderer does what was intended; `../scripts/check_artifacts.sh` proves the intended output is valid to `dhcpd`, the installer and `cloud-init`. Both matter: the second found three bugs the first couldn't.

The tag-contract test is the one that spans labs. Terraform stamps the tags, lab 2's `aws_ec2` inventory turns them into groups, and the playbooks target those groups by name — with nothing checking the link. A typo means `--limit tag_Role_database` matches nothing, the play reports "no hosts matched", and **exits 0**. A rollout that touched zero hosts looks exactly like success, which is why it is asserted here rather than discovered during one.
