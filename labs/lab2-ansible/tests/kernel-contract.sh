#!/usr/bin/env bash
# =============================================================================
# kernel role: input contract and merge behaviour.
#
#   tests/kernel-contract.sh
#
# Two things are tested, and the second is the interesting one.
#
# 1. BAD INPUT IS REJECTED, with a message naming the problem, before anything
#    is written. Same two layers as the baseline role: argument_specs for types
#    and choices, tasks/validate.yml for anything that depends on this host.
#
# 2. THE KEY-AWARE MERGE on the RHEL-family bootloader file. This is the part of
#    the role most likely to be got wrong by a rewrite, because the wrong
#    version looks right: appending the arguments passes any "is my setting
#    there?" test and quietly leaves `hugepages=99 hugepages=8` on the boot
#    line. So the test seeds a realistic vendor file with a STALE value of an
#    argument the role manages, and requires that the vendor's own arguments
#    survive, the stale one is gone, and no key appears twice.
#
# exit 0 = every case behaved as required
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

INV=inventory/kernel-hosts.yml
pass=0
fail=0

docker inspect lab-ktr-rhel >/dev/null 2>&1 || {
  echo "lab-ktr-rhel is not running - run ./setup-distros.sh first"
  exit 2
}

expect_rejected() {
  local label="$1" expected="$2" host="$3" extra_vars="$4"
  local out rc
  out="$(ansible-playbook -i "$INV" kernel.yml --check --limit "$host" -e "$extra_vars" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] && grep -qF -- "$expected" <<< "$out"; then
    printf '   PASS  %-56s -> "%s"\n' "$label" "$expected"
    pass=$((pass + 1))
  else
    printf '   FAIL  %-56s (rc=%s, message not found: "%s")\n' "$label" "$rc" "$expected"
    fail=$((fail + 1))
  fi
}

assert_line() {
  local label="$1" test_expr="$2"
  if eval "$test_expr"; then
    printf '   PASS  %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '   FAIL  %s\n' "$label"
    fail=$((fail + 1))
  fi
}

echo "== argument_specs: types and choices, before any task runs"
expect_rejected "a profile that does not exist" \
  "value of kernel_profile must be one of" ktr-rhel \
  '{"kernel_profile": "web-server"}'
expect_rejected "a limits entry for an item PAM does not know" \
  "must be one of" ktr-rhel \
  '{"kernel_limits_extra": [{"domain": "*", "item": "bandwidth", "value": 10}]}'
expect_rejected "a limits entry missing its domain" \
  "missing required arguments: domain" ktr-rhel \
  '{"kernel_limits_extra": [{"item": "nofile", "value": 1024}]}'

echo
echo "== validate.yml: rules that depend on THIS host"

# The check that earns its keep. tcp_tw_recycle was removed from the kernel in
# 4.12 and is still in tuning guides; a kernel that does not have the key either
# ignores the whole file or aborts on it, so the role refuses to write it.
expect_rejected "a sysctl key removed from the kernel (tcp_tw_recycle)" \
  "not present in this kernel's /proc/sys" ktr-rhel \
  '{"kernel_sysctl_strict": true, "kernel_sysctl_extra": {"net.ipv4.tcp_tw_recycle": 1}}'

expect_rejected "a sysctl key that is simply a typo" \
  "not present in this kernel's /proc/sys" ktr-rhel \
  '{"kernel_sysctl_strict": true, "kernel_sysctl_extra": {"vm.swapiness": 10}}'

# The kernel splits its command line on spaces, so one list item holding two
# arguments becomes one argument the kernel silently ignores.
expect_rejected "two boot arguments in one list item" \
  "contains whitespace" ktr-rhel \
  '{"kernel_cmdline_extra": ["hugepagesz=1G hugepages=8"]}'

# Promising to load values at runtime on a host with no sysctl binary is a
# promise the role cannot keep. All four of these images happen to ship procps
# (Ubuntu 24.04 does, which is where the first version of this case went wrong
# by assuming otherwise), so the missing binary is simulated by pointing the
# role at a path that is not there - which is exactly the state of a minimal
# image before the baseline role has installed anything.
expect_rejected "runtime load requested with no sysctl binary" \
  "does not exist" ktr-ubuntu \
  '{"kernel_sysctl_apply": true, "kernel_sysctl_binary": "/usr/sbin/sysctl-not-installed"}'

echo
echo "== the key-aware merge on a realistic vendor /etc/default/grub"

# A real RHEL 9 line, plus a stale value for two arguments the role manages.
docker exec lab-ktr-rhel sh -c 'cat > /etc/default/grub <<EOF
GRUB_TIMEOUT=5
GRUB_DEFAULT=saved
GRUB_CMDLINE_LINUX="crashkernel=1G-4G:192M resume=/dev/mapper/rhel-swap rd.lvm.lv=rhel/root console=ttyS0,115200 hugepages=99 transparent_hugepage=always"
GRUB_DISABLE_RECOVERY="true"
EOF'

ansible-playbook -i "$INV" kernel.yml --limit ktr-rhel --tags kernel_bootloader >/dev/null 2>&1
line="$(docker exec lab-ktr-rhel sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/\1/p' /etc/default/grub)"
echo "   line: $line"

assert_line "the distribution's crashkernel is preserved" \
  '[[ "$line" == *"crashkernel=1G-4G:192M"* ]]'
assert_line "the distribution's resume/rd.lvm.lv/console are preserved" \
  '[[ "$line" == *"resume=/dev/mapper/rhel-swap"* && "$line" == *"rd.lvm.lv=rhel/root"* && "$line" == *"console=ttyS0,115200"* ]]'
assert_line "the STALE hugepages=99 is gone" \
  '[[ "$line" != *"hugepages=99"* ]]'
assert_line "the STALE transparent_hugepage=always is gone" \
  '[[ "$line" != *"transparent_hugepage=always"* ]]'
assert_line "the role's current values are present" \
  '[[ "$line" == *"transparent_hugepage=never"* && "$line" == *"hugepages=8"* ]]'
# The assertion that catches the naive "just append" implementation.
assert_line "no key appears twice" \
  '[ "$(tr " " "\n" <<< "$line" | sed "s/=.*//" | sort | uniq -d | wc -l | tr -d " ")" = "0" ]'
assert_line "the other GRUB_ settings in the file are untouched" \
  'docker exec lab-ktr-rhel grep -q "^GRUB_TIMEOUT=5$" /etc/default/grub && docker exec lab-ktr-rhel grep -q "^GRUB_DISABLE_RECOVERY=\"true\"$" /etc/default/grub'

# Removing an argument from the request must remove it from the line: the whole
# point of a declarative merge rather than an append.
ansible-playbook -i "$INV" kernel.yml --limit ktr-rhel --tags kernel_bootloader \
  -e '{"kernel_profile": "general"}' >/dev/null 2>&1
line_after="$(docker exec lab-ktr-rhel sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/\1/p' /etc/default/grub)"
assert_line "switching to a profile with no boot arguments removes them" \
  '[[ "$line_after" != *"transparent_hugepage"* && "$line_after" != *"hugepages"* ]]'
assert_line "and still keeps the distribution's arguments" \
  '[[ "$line_after" == *"crashkernel=1G-4G:192M"* ]]'

# Put the host back where the other tests expect it.
ansible-playbook -i "$INV" kernel.yml --limit ktr-rhel >/dev/null 2>&1

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
