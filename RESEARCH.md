# RESEARCH.md — sources, verification, and the bugs found along the way

This file makes the repository reproducible and auditable: which versions were used, where the design guidance comes from, how each result was verified, and every defect found while building it, including how it was found. A record of bugs caught is more useful than a claim that there were none.

## 1. Environment

| Tool | Version |
|---|---|
| macOS (Apple Silicon), Docker via OrbStack | Darwin 25.6, Docker 29.4.0 |
| Terraform | 1.16.1 |
| tflint / trivy / checkov | 0.61.0 / 0.74.0 / 3.3.10 |
| ansible-core / ansible-lint | 2.21.4 / 26.8.0 |
| Collections (pinned in `labs/lab2-ansible/requirements.yml`) | community.docker 5.3.0, ansible.posix 2.2.2, community.library_inventory_filtering_v1 1.1.5 |
| Python / PyYAML / jq / GNU Make | 3.14.7 / 6.0.3 / 1.8.2 / 3.81 |
| Lab host image | `almalinux:9` (AlmaLinux 9.8), aarch64 |
| Real-parser checks (in container) | ISC `dhcp-server` and `pykickstart` from AlmaLinux 9 repositories |

## 2. Sources

**Terraform**
- `for_each`, `count`, and "Invalid for_each argument" (keys known at plan time): Terraform language documentation, *The for_each Meta-Argument*.
- `moved` blocks for refactoring (Terraform 1.1+) and `import` blocks (1.5+): Terraform documentation, *Refactoring* and *Import*.
- `terraform test`, `expect_failures`, and plan-time evaluation limits: Terraform documentation, *Tests*.
- `optional()` object attributes with defaults (1.3+): Terraform documentation, *Type Constraints*.
- S3-native state locking with `use_lockfile` (1.10+) and deprecation of `dynamodb_table` (1.11): [S3 native state locking](https://www.bschaatsbergen.com/s3-native-state-locking), [explainer](https://dev.to/aws-builders/terraform-state-locking-without-dynamodb-s3-native-locking-explained-448l).

**Ansible**
- Role argument validation (`meta/argument_specs.yml`): Ansible documentation, *Roles — role argument validation*.
- Rolling updates, `serial`, `max_fail_percentage`: Ansible documentation, *Controlling playbook execution*; [rolling updates and failure controls](https://oneuptime.com/blog/post/2026-07-24-ansible-rolling-updates/view), [max_fail_percentage](https://oneuptime.com/blog/post/2026-02-21-ansible-max-fail-percentage-failure-thresholds/view).
- Windows over WinRM: transports, CredSSP delegation risk, Kerberos under FIPS, the double hop: [Ansible WinRM documentation](https://docs.ansible.com/projects/ansible/latest/os_guide/windows_winrm.html).
- sshd reads configuration in order and uses the first value obtained for most keywords: `sshd_config(5)`.

**Bare metal**
- Kickstart syntax, and the absence of line continuation: `pykickstart` / RHEL 9 installation documentation; confirmed with `ksvalidator -v RHEL9`.
- iPXE chainloading, the `user-class "iPXE"` loop-breaker, and declaring RFC 4578 option 93 in ISC dhcpd: iPXE documentation, *Chainloading iPXE*; confirmed with `dhcpd -t`.
- Bare-metal provisioning tooling (Ironic, Foreman, MAAS, Tinkerbell, Redfish): [bare metal automation overview](https://www.atlantic.net/dedicated-server-hosting/bare-metal-automation-provisioning-tools-lifecycle-management/), [provisioning explainer](https://netactuate.com/blog/bare-metal-provisioning).

**Platforms**
- Spacelift concepts (stacks, spaces, Rego policies, drift detection, worker pools): [spacelift.io](https://spacelift.io/terraform-automation), [multicloud governance](https://spacelift.io/blog/spacelift-multicloud).
- Alibaba Cloud service mapping and the `alicloud` provider: [Terraform overview (ACK)](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/developer-reference/terraform-overview), [OSS Terraform](https://www.alibabacloud.com/help/en/oss/developer-reference/terraform-overview/).

## 3. Verification log

Reproduce everything automated with `make all`. Results as run:

| Check | Command | Result |
|---|---|---|
| Terraform static | `make lab1-static` | fmt clean; 8 roots `validate` OK; `tflint` rc=0 on all 8 |
| Terraform scan | `make lab1-scan` | trivy: 0 misconfigurations (local-only resources; the gate exists for real providers) |
| Module tests | `make lab1-test` | 16 passed, 0 failed (12 plan + 4 apply), ~2 s |
| Guard-rail mutation | remove prod replica precondition / `:latest` validation in a scratch copy | the matching test fails in each case |
| Integration mutation | 7 mutations: shared deploy-id keepers, wrong listener target, HTTP listeners, hard-coded image, deletion protection off, `web` not removed, `create_before_destroy` restored | each turns at least one apply run red (table in `modules/app_stack/tests/README.md`) |
| Live environments | `make lab1-e2e` | dev 9 + prod 15 applied; `verify-env.py` 6/6 on both; tamper → 3 checks fail; `apply` → 2 still fail; delete + `-replace` → 6/6; destroy 9 + 15; `--destroyed` 2/2 on both; ~7 s |
| Verifier mutation | 6 out-of-band changes to live prod: delete a listener, scale api to 1, unmanaged file, rewire a listener to worker over HTTP, chmod 666, deletion protection off + tag removed | every one fails the named checks (`exists`/`wiring`/`outputs`; `integrity`/`policy`; `unmanaged`; `integrity`/`wiring`/`policy`; `integrity`; `integrity`/`policy`) |
| `for_each` examples | `make tf-examples` | 01: count 2 replace + 1 destroy vs for_each 1 destroy · 02: unknown-key error reproduced; budget change updates 1 key · 03: add CIDR → stable 2 creates, positional 4 replaces · 04: without `moved` 3 destroy + 3 create; with `moved` 3 moves, same object id |
| Env roots | `terraform plan` / `apply` / `destroy` | dev 9 resources, prod 15 |
| `for_each` isolation | plan removing `web` / bumping `api` image | only `web`'s 4 resources / only `api`'s 3 resources |
| Terraform drift | tamper → `drift-check.sh` → apply → `drift-check.sh` | exit 2 + record → exit 0, record kept |
| Ansible lint | `make lab2-static` | production profile: 0 failures |
| Converge | `ansible-playbook site.yml` | 6 hosts, `sshd effective config matches baseline` on all |
| Idempotence | `tests/idempotence.sh` | 6 hosts, `changed=0` on run 2 |
| Anti-patterns | idempotence test on `not-idempotent.yml` / `idempotent.yml` | 6 of 6 tasks changed / 0 changed |
| Lint vs. anti-patterns | ansible-lint (production) on `not-idempotent.yml` | 5 of 6 tasks flagged; the timestamp task not flagged |
| Input contract | `tests/input-validation.sh` | 8 of 8 rejected with the expected message |
| Effective-config check | `99-` drop-in on `web02` without `10-` | tasks succeed, `sshd -T` shows `permitrootlogin yes`, verify fails the host |
| Rolling patch | `patch.yml`, then `--limit @reports/patch.retry` | stops after web01, web02, web03; db/app untouched; retry run: 3 of 3 patched |
| Ansible drift | tamper db01 → `drift-check.sh` → converge → `drift-check.sh` | exit 2 (1 host, 2 tasks) + record → exit 0, record kept |
| Bare-metal unit tests | `make lab3-test` | 20 passed |
| Fallback-reader mutation | remove int parsing in the stdlib YAML reader | test fails |
| Line-continuation mutation | wrap the kickstart `network` line | test fails |
| Real parsers | `make lab3-artifacts` | `dhcpd -t` pass (and fails without the generated include); `ksvalidator -v RHEL9` pass on 3 files |
| Acceptance play | `ansible-lint`, `--syntax-check` against generated inventory | pass / pass |

## 4. Bugs found while building this, and how

### Terraform

| # | Bug | Found by | Fix |
|---|---|---|---|
| T1 | One `random_id` shared by every service (keepers = the service set): removing `web` **replaced `api`** | planning a key removal and reading the JSON plan | per-service `random_id.deploy[each.key]`; regression test `deploy_ids_are_keyed_per_service` |
| T2 | A test asserted on rendered `content`, which embeds an apply-time value: *"Condition expression could not be evaluated at this time"* | `terraform test` | assert on the typed variable, which is known at plan |
| T3 | A mutation of `condition = true` rejected by Terraform: *"must refer to at least one object"* | the mutation check itself | mutate to an always-true expression that references `each.value` |
| T4 | `drift-check.sh` `cd`'d into the root and then deleted the saved plan, so it was invisible and gone | a user looking for the file | explicit archive + `KEEP_PLAN=1` |
| T5 | Drift `index.csv` invalid: `for_each` addresses contain `"` | parsing with `csv.DictReader` | RFC 4180 quote doubling |
| T6 | Two drift runs in the same UTC second would target one read-only record directory, losing the second | reasoning about read-only records; tested by pre-creating directories | `-2`, `-3` suffixes |
| T7 | Drift viewer printed two identically truncated JSON blobs for a changed attribute | viewing a real `replace` | flatten JSON-valued attributes: `content.image: web:2.1.0 -> web:2.2.0` |
| T8 | A `sed` meant to change an image tag matched nothing, so a test "passed" while testing nothing | re-reading the output | re-run against the real value; lesson applied in `tamper.sh` |
| T9 | Example 04's cleanup left `.work/` behind: the trap used a relative path after `cd` | `ls` after the demo | absolute path |
| T10 | `terraform import` isn't supported by `local_file` | trying it | `import` block shown as reference; `-replace` demonstrated live |
| T11 | `create_before_destroy = true` on the fixed-name datastore: `apply -replace` created the new file, then destroyed the old one **at the same path**. `Apply complete! 1 added, 1 destroyed`, resource in state, nothing on disk | `verify-env.py` `exists` check after a remediation | lifecycle block removed; integration run `replace_datastore` (mutation-checked) |
| T12 | Prod was only ever *planned* in the README walkthrough, so cleanup reported `0 destroyed` for prod and nothing had tested a live environment | a user running cleanup | Exercise A applies both roots; Exercise B verifies them; `make lab1-e2e` runs the lifecycle |
| T13 | Permission drift is invisible to Terraform: `local_file` doesn't refresh file mode, so `plan` said *No changes* on a 0666 datastore and `apply` didn't fix it | `verify-env.py` still failing after a successful apply | documented as a plan blind spot; `integrity` check compares mode; remediated with `-replace` |
| T14 | With the datastore missing, the verifier derived the environment from it and reported every object as mis-tagged | reading the failure output | environment taken from the first readable object |

### Ansible

| # | Bug | Found by | Fix |
|---|---|---|---|
| A1 | AlmaLinux 9 image ships `sshd_config.d/25-permitrootlogin.conf` (`PermitRootLogin yes`); a later-sorting hardening drop-in is silently overridden | probing `sshd -T` before writing the role | drop-in named `10-baseline.conf`; `verify.yml` asserts on `sshd -T` |
| A2 | `argument_specs` accepts a YAML boolean for a `str` option whose choices include `"no"`/`"yes"`; it reached the template as `False` | `tests/input-validation.sh` case failing with an unexpected message | explicit `is string` assertion in `validate.yml` |
| A3 | Minimal image has no `/etc/sysctl.d` and no `sysctl` binary | first converge failed | `file: state=directory`; `procps-ng` in baseline packages |
| A4 | Verification in check mode would fail on every drifted host, turning DRIFT into INCOMPLETE | reasoning through `drift-check.sh` exit codes | verify skipped when `ansible_check_mode` |
| A5 | `ansible-playbook --check` exits 0 when it finds drift | running it | wrapper derives exit 2 from per-host `changed` |
| A6 | JSON callback output corrupted by `profile_tasks` lines; `ANSIBLE_CALLBACKS_ENABLED=` (empty) crashes ansible-core 2.21 | parsing failures | set it to `ansible.posix.json` |
| A7 | An unreachable host produced **no drift record**: the retry-file hint is printed to stdout above the JSON | a nonexistent `ghost01` host | `ANSIBLE_RETRY_FILES_ENABLED=false` for read-only runs |
| A8 | Template diffs recorded the controller's temp path (including a local home directory) as the "after" header | reading a drift record | viewer shows destination file + template name |
| A9 | On a fresh clone `reports/run/` doesn't exist; the canary's first record write failed | running `patch.yml` after deleting `reports/` | play creates the directory first |
| A10 | A `rescue`d failure is not counted toward `max_fail_percentage`; the run continued into the next batch | a control play with a plain failing command | fail the host again outside the block |
| A11 | Retry file lists the whole aborted batch, including the host that passed | reading `patch.retry` | documented; harmless because the role is idempotent |
| A12 | `community.docker` 3.3.2 in the user collection path shadowed 5.3.0 and broke on ansible-core 2.21 | connection errors | project-local `collections_path` + pinned `requirements.yml` |
| A13 | Containers have no usable `HOME` for remote tmp | module failures | `remote_tmp = /tmp/.ansible` |
| A14 | `lookup('file', ...)` reads the **controller**, not the target | wrong content | `command: cat` on the target |
| A15 | Tampering before the baseline existed: `/etc/ssh` absent on fresh hosts | a user running the drift demo | `tamper.sh` refuses without a baseline and verifies the edit landed |
| A16 | A first verification of the override case passed vacuously because the correct `10-` file was still present | noticing the result was too good | removed `10-` first; the check then failed as intended |

### Bare metal

| # | Bug | Found by | Fix |
|---|---|---|---|
| B1 | `option architecture-type` isn't defined in ISC dhcpd; the server would refuse to start | `dhcpd -t` | declare `option client-arch code 93 = unsigned integer 16;` |
| B2 | Kickstart `network` command wrapped with `\`: parsed as unknown commands, so the bond/IP/VLAN would never be configured | `ksvalidator -v RHEL9` | one line; unit test forbids trailing backslashes |
| B3 | `%packages --minimal` isn't a valid option | `ksvalidator` | removed; `@^minimal-environment` already selects the minimal set |
| B4 | Generated DHCP reservations spanning two subnets were included inside one subnet block | reviewing ISC dhcpd scoping | include at global scope |
| B5 | `cat | grep` pipeline without `pipefail` in the acceptance play would mask a missing bond | ansible-lint `risky-shell-pipe` | `grep` reads the file directly |

## 5. Known limits

- Lab resources are local stand-ins. Real-provider behaviour (API errors, eventual consistency, provider-specific ForceNew attributes) is described, not exercised.
- Lab hosts are containers without systemd or their own kernel, so service reloads and `sysctl -p` are skipped by design. Those handler paths run on VMs and physical hosts.
- `bmc_baseline.sh` and `acceptance.yml` target hardware that doesn't exist here; they are syntax-checked and linted, not executed.
- The CI workflow calls the verified `make` targets but hasn't yet run on GitHub-hosted runners.
