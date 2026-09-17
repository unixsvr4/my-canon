#!/usr/bin/env bash
# =============================================================================
# Input-contract test: bad variables must be REJECTED before any task touches
# a host, with a message that names the problem.
#
# Two layers are exercised:
#   meta/argument_specs.yml  - types and choices, enforced by ansible-core
#   tasks/validate.yml       - rules spanning several variables
#
# Each case runs in --check mode against one host, so even a guard that failed
# to fire would change nothing.
#
# exit 0 = every bad input was rejected with the expected message
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0

expect_rejected() {
  local label="$1" expected="$2" extra_vars="$3"
  local out
  out="$(ansible-playbook site.yml --check --limit web01 -e "$extra_vars" 2>&1)"
  local rc=$?
  if [ $rc -ne 0 ] && grep -qF -- "$expected" <<< "$out"; then
    printf '   PASS  %-58s -> "%s"\n' "$label" "$expected"
    pass=$((pass + 1))
  else
    printf '   FAIL  %-58s (rc=%s, expected message not found: "%s")\n' "$label" "$rc" "$expected"
    fail=$((fail + 1))
  fi
}

echo "== argument_specs: types and choices"
expect_rejected "PermitRootLogin outside the allowed choices" \
  "must be one of" '{"baseline_ssh_permit_root_login": "maybe"}'
expect_rejected "MaxAuthTries is not an integer" \
  "baseline_ssh_max_auth_tries" '{"baseline_ssh_max_auth_tries": "lots"}'
expect_rejected "admin user state outside present/absent" \
  "must be one of" '{"baseline_admin_users": [{"name": "dave", "state": "gone"}]}'
expect_rejected "admin user without the required name" \
  "missing required arguments: name" '{"baseline_admin_users": [{"key": "ssh-ed25519 AAAA"}]}'

echo "== validate.yml: rules across variables"
# argument_specs lets this through (a boolean "matches" the yes/no choices);
# the explicit type assertion in tasks/validate.yml is what rejects it.
expect_rejected "YAML gotcha: bare no is a boolean, not the string \"no\"" \
  "must be a quoted string" '{"baseline_ssh_permit_root_login": false}'
expect_rejected "duplicate admin user names" \
  "lists the same name twice" '{"baseline_admin_users": [{"name": "dave"}, {"name": "dave"}]}'
expect_rejected "_extra silently overriding a role-owned sysctl" \
  "redefines role-owned keys" '{"baseline_sysctl_extra": {"vm.swappiness": 1}}'
expect_rejected "root login open while passwords are allowed" \
  "is refused by this role" '{"baseline_ssh_permit_root_login": "yes", "baseline_ssh_password_authentication": true}'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
