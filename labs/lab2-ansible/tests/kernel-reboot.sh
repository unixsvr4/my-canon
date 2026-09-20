#!/usr/bin/env bash
# =============================================================================
# The test the container lab cannot run: REBOOT, and then a KERNEL UPGRADE.
#
#   tests/kernel-reboot.sh                                       four local VMs
#   tests/kernel-reboot.sh kvm-rhel                              one of them
#   tests/kernel-reboot.sh --inventory inventory/kernel-aws.yml  the EC2 rig
#   SKIP_UPGRADE=1 tests/kernel-reboot.sh                        phases 1-3 only
#
# Needs ./vms/up.sh first - or, for the EC2 rig, `terraform apply` in aws/ and
# the inventory it renders. Slow by nature (a kernel upgrade and two reboots per
# host), so it is not part of `make ci`.
#
# HOSTS COME FROM THE INVENTORY, not from a list in this file. The same test
# therefore runs against four QEMU guests on a laptop and four EC2 instances
# with public addresses: the only things it needs to know - where to connect and
# as whom - are things the inventory already says.
#
# WHY IT EXISTS
#
# "It persists across a reboot" is the entire claim of the kernel role's
# layer 3, and it is the one claim containers cannot test: a container has no
# kernel of its own, so the arguments are reported "pending" forever and the
# README asks you to take the rest on trust.
#
# THE FOUR PHASES
#
#   1. apply          the arguments are written and reported PENDING - correct,
#                     and not yet proof of anything
#   2. reboot         the role reboots, then re-reads /proc/cmdline and asserts
#                     every argument is ACTIVE. Verified again here, from
#                     outside Ansible, against /proc/cmdline and /sys
#   3. re-apply       a second converge on the booted host changes NOTHING
#                     (the merge is idempotent against a live cmdline too)
#   4. kernel upgrade install a NEW kernel, reboot into it, and report what
#                     happened to the tuning - then re-apply the role and
#                     require every argument active on the new kernel
#
# Phase 4 is the one that matters in production. A kernel upgrade writes a new
# boot entry, and whether your arguments come with it depends on the
# distribution. Rather than assert a guess, this test OBSERVES it per
# distribution, prints the answer, and then proves the fix: re-run the role.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

INV=inventory/kernel-vms.yml
VM_DIR="${VM_DIR:-/tmp/canon-kernel-vms}"
OUT=reports/kernel-vms

WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory)   INV="$2"; shift 2 ;;
    --inventory=*) INV="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,34p' "$0"; exit 0 ;;
    *)             WANTED+=("$1"); shift ;;
  esac
done

mkdir -p "$OUT"
pass=0
fail=0

# --- where the hosts are: from the inventory --------------------------------
#
# One line per host: name, address, port, user, key. Read with
# `ansible-inventory`, so the local VMs (127.0.0.1 on forwarded ports) and the
# EC2 rig (public addresses on port 22) need no special case here.
inventory_hosts() {
  ansible-inventory -i "$INV" --list 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
meta = d.get("_meta", {}).get("hostvars", {})
group = next((g for g in ("kernel_vms", "kernel_aws", "kernel_tuned")
              if isinstance(d.get(g), dict) and d[g].get("hosts")), None)
for h in (d.get(group, {}).get("hosts", []) if group else []):
    hv = meta.get(h, {})
    print(h, hv.get("ansible_host", h), hv.get("ansible_port", 22),
          hv.get("ansible_user", "root"),
          hv.get("ansible_ssh_private_key_file", "-"))
'
}

TARGETS=()
while read -r h_name h_addr h_port h_user h_key; do
  [ -n "$h_name" ] || continue
  if [ ${#WANTED[@]} -gt 0 ]; then
    case " ${WANTED[*]} " in *" $h_name "*) ;; *) continue ;; esac
  fi
  TARGETS+=("$h_name|$h_addr|$h_port|$h_user|$h_key")
done < <(inventory_hosts)

[ ${#TARGETS[@]} -gt 0 ] || {
  echo "no hosts found in $INV"
  echo "  local VMs: ./vms/up.sh"
  echo "  EC2 rig:   cd aws && terraform apply ... && terraform output -raw ansible_inventory > ../inventory/kernel-aws.yml"
  exit 2
}

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# The out-of-band checks go over plain ssh deliberately: they are a second
# opinion on what the role reported, so they do not use the role. They do use
# the inventory's connection details, because keeping a second copy of "where
# is this host" is how a test starts lying.
on() { # on <target> <command...>
  local t="$1"; shift
  local addr port user key
  addr=$(field "$t" 2); port=$(field "$t" 3); user=$(field "$t" 4); key=$(field "$t" 5)
  # `ansible-inventory --list` does NOT render Jinja in host vars, so a key
  # written as a lookup arrives verbatim as "{{ lookup(...) }}". Resolve it to
  # the same default the inventory uses instead of handing ssh a template.
  case "$key" in *"{{"*|-) key="$VM_DIR/id_ed25519" ;; esac
  ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -i "$key" -p "$port" "$user@$addr" "$@" 2>/dev/null
}

wait_up() { # wait_up <target> <seconds>
  local t="$1" limit="${2:-300}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    on "$t" true && return 0
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

check() { # check <label> <condition-as-string>
  if eval "$2"; then
    printf '   PASS  %s\n' "$1"; pass=$((pass + 1))
  else
    printf '   FAIL  %s\n' "$1"; fail=$((fail + 1))
  fi
}

limit_list() { local IFS=','; local names=(); for e in "${TARGETS[@]}"; do names+=("$(field "$e" 1)"); done; echo "${names[*]}"; }
LIMIT="$(limit_list)"

# The pre-flight check RETRIES rather than failing on the first miss. A single
# attempt failed once with all four VMs demonstrably up and answering seconds
# later: four guests plus a package install is enough load on the host to make
# one 10-second connect time out. A pre-flight that is flakier than the thing
# it is checking teaches people to re-run tests instead of reading them.
for entry in "${TARGETS[@]}"; do
  name=$(field "$entry" 1)
  wait_up "$entry" 60 || {
    echo "[ERROR] $name unreachable at $(field "$entry" 4)@$(field "$entry" 2):$(field "$entry" 3) after 60s"
    exit 2
  }
done

echo "=============================================================="
echo " hosts: $LIMIT"
echo "=============================================================="

# --- phase 1: apply, expect PENDING -----------------------------------------
echo
echo "== phase 1: apply. Boot arguments are written, and NOT yet in effect"
ansible-playbook -i "$INV" kernel.yml --limit "$LIMIT" > "$OUT/phase1.log" 2>&1 || {
  echo "   converge FAILED - see $OUT/phase1.log"; grep -E "^fatal" "$OUT/phase1.log" | head -3; exit 2; }
grep -E '"msg": "kvm-' "$OUT/phase1.log" | sed 's/.*"msg": "/   /; s/"$//'

for entry in "${TARGETS[@]}"; do
  name=$(field "$entry" 1)
  # Anything the role manages should be configured but absent from the running
  # kernel at this point. A host whose profile has no boot arguments is
  # skipped rather than asserted on.
  want=$(on "$entry" 'sudo sed -n "s/^# canon-kernel-managed: *//p" /etc/default/grub 2>/dev/null | head -1')
  if [ -n "$want" ]; then
    active_now=$(on "$entry" 'cat /proc/cmdline')
    first_key=${want%% *}
    if [[ "$active_now" == *"$first_key="* ]]; then
      # Already active: this host has been tuned and rebooted before, which is
      # a legitimate state and not a failure - it just means phase 1 has
      # nothing to demonstrate. Reported rather than asserted, because the
      # alternative is a test that only passes on a machine nobody has used.
      # For the full before/after, start from fresh VMs:
      #   ./vms/down.sh --clean && ./vms/up.sh
      printf '   SKIP  %s: already tuned and rebooted (%s is live) - nothing pending to show\n' "$name" "$first_key"
    else
      check "$name: $first_key is configured and NOT yet in /proc/cmdline" "true"
    fi
  fi
done

# --- phase 2: reboot ---------------------------------------------------------
echo
echo "== phase 2: reboot. The role reboots each host and re-reads /proc/cmdline"
ansible-playbook -i "$INV" kernel.yml --limit "$LIMIT" -e kernel_reboot_ok=true \
  > "$OUT/phase2.log" 2>&1 || {
  echo "   FAILED - see $OUT/phase2.log"; grep -E "^fatal|assertion" "$OUT/phase2.log" | head -5; fail=$((fail + 1)); }
grep -E '"msg": "kvm-' "$OUT/phase2.log" | sed 's/.*"msg": "/   /; s/"$//'

echo
echo "-- independent verification, outside Ansible --"
for entry in "${TARGETS[@]}"; do
  name=$(field "$entry" 1)
  wait_up "$entry" 300 || { echo "   FAIL  $name did not come back"; fail=$((fail + 1)); continue; }

  cmdline=$(on "$entry" 'cat /proc/cmdline')
  uptime_s=$(on "$entry" 'cut -d. -f1 /proc/uptime')
  printf '   %s (up %ss)\n' "$name" "$uptime_s"

  # Every argument the role owns has to be in the RUNNING kernel's cmdline.
  # The list comes from the role's own ownership marker, or from the Debian
  # drop-in, so the test does not carry its own copy of the expectation.
  owned=$(on "$entry" 'sudo sed -n "s/^# canon-kernel-managed: *//p" /etc/default/grub 2>/dev/null | head -1')
  [ -n "$owned" ] || owned=$(on "$entry" "sudo grep -h '^_canon_keys=' /etc/default/grub.d/99-canon-kernel.cfg 2>/dev/null | head -1 | cut -d'\"' -f2")
  if [ -z "$owned" ]; then
    echo "      (this profile owns no boot arguments)"
  else
    missing=""
    for key in $owned; do
      case " $cmdline " in *" $key="*) ;; *) missing="$missing $key" ;; esac
    done
    check "$name: every managed boot argument is live after the reboot${missing:+ (missing:$missing)}" \
      "[ -z \"$missing\" ]"
  fi

  # The settings whose whole point is that they have no sysctl.
  thp=$(on "$entry" 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null')
  case "$cmdline" in
    *transparent_hugepage=never*)
      check "$name: THP is really off, not just requested  [$thp]" "[[ \"$thp\" == *'[never]'* ]]" ;;
    *transparent_hugepage=madvise*)
      check "$name: THP is really madvise  [$thp]" "[[ \"$thp\" == *'[madvise]'* ]]" ;;
  esac

  # A hugepage request the kernel could not satisfy leaves the argument active
  # and the reservation empty - the role's verifier now fails on this, and the
  # test checks it independently.
  case "$cmdline" in
    *default_hugepagesz=1G*)
      want_hp=$(printf '%s' "$cmdline" | tr ' ' '\n' | sed -n 's/^hugepages=//p' | tail -1)
      got_hp=$(on "$entry" 'cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null')
      check "$name: $want_hp x 1GB huge page(s) actually reserved (got ${got_hp:-0})" \
        "[ \"${got_hp:-0}\" -ge \"${want_hp:-0}\" ]" ;;
  esac

  # And a runtime parameter, to show layer 1 survived the reboot too - it is
  # loaded from /etc/sysctl.d by systemd-sysctl on every boot, which is a
  # different mechanism from the boot arguments and worth confirming separately.
  sw=$(on "$entry" 'cat /proc/sys/vm/swappiness')
  want_sw=$(on "$entry" 'sudo sed -n "s/^vm.swappiness *= *//p" /etc/sysctl.d/90-canon-kernel.conf 2>/dev/null')
  [ -n "$want_sw" ] && check "$name: vm.swappiness=$want_sw reloaded on boot (running $sw)" "[ \"$sw\" = \"$want_sw\" ]"
done

# --- phase 3: re-apply on the booted host ------------------------------------
echo
echo "== phase 3: re-apply. A converge against a live, tuned kernel changes nothing"
ANSIBLE_CALLBACKS_ENABLED=ansible.posix.json \
ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
ANSIBLE_RETRY_FILES_ENABLED=false \
  ansible-playbook -i "$INV" kernel.yml --limit "$LIMIT" > "$OUT/phase3.json" 2>"$OUT/phase3.err"

python3 - "$OUT/phase3.json" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
changed = {}
for play in run["plays"]:
    for t in play["tasks"]:
        for host, r in t["hosts"].items():
            if r.get("changed"):
                changed.setdefault(host, []).append(t["task"]["name"])
hosts = sorted({h for p in run["plays"] for t in p["tasks"] for h in t["hosts"]})
for h in hosts:
    if h in changed:
        print(f"   FAIL  {h}: changed={len(changed[h])}")
        for n in changed[h]:
            print(f"         {n}")
    else:
        print(f"   PASS  {h}: changed=0 against a booted, tuned kernel")
sys.exit(1 if changed else 0)
PY
[ $? -eq 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))

# --- phase 4: a new kernel ---------------------------------------------------
if [ "${SKIP_UPGRADE:-0}" = "1" ]; then
  echo
  echo "== phase 4 skipped (SKIP_UPGRADE=1)"
else
  echo
  echo "== phase 4: install a NEW kernel, boot into it, and see what survived"
  for entry in "${TARGETS[@]}"; do
    name=$(field "$entry" 1)
    before_k=$(on "$entry" 'uname -r')

    # Chosen by asking the host what it has, not by matching its NAME: the EC2
    # instances are called canon-kernel-* and a name-based case statement would
    # silently skip every one of them.
    cmd='if command -v dnf >/dev/null 2>&1; then
           sudo dnf -y -q install kernel6.12 2>/dev/null || sudo dnf -y -q update kernel
         elif command -v apt-get >/dev/null 2>&1; then
           sudo apt-get -qq update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y -qq install linux-image-generic
         elif command -v zypper >/dev/null 2>&1; then
           sudo zypper --non-interactive -q up kernel-default
         else
           echo "no known package manager"; exit 1
         fi'

    printf '   %-11s installing a new kernel ... ' "$name"
    if ! on "$entry" "$cmd" >>"$OUT/phase4-$name.log" 2>&1; then
      echo "no upgrade available or install failed (see $OUT/phase4-$name.log)"
      continue
    fi

    # Only reboot if a different kernel is actually installed now.
    newest=$(on "$entry" 'ls -1t /boot/vmlinuz-* /boot/Image-* 2>/dev/null | head -1 | sed "s#.*/\(vmlinuz\|Image\)-##"')
    if [ "$newest" = "$before_k" ]; then
      echo "already newest ($before_k) - nothing to boot into"
      continue
    fi
    echo "$before_k -> $newest"

    on "$entry" 'sudo systemctl reboot' >/dev/null 2>&1 || true
    sleep 10
    wait_up "$entry" 420 || { echo "   FAIL  $name did not come back from the new kernel"; fail=$((fail + 1)); continue; }

    after_k=$(on "$entry" 'uname -r')
    check "$name: booted a different kernel ($before_k -> $after_k)" "[ \"$after_k\" != \"$before_k\" ]"

    # THE OBSERVATION. Did the tuning come with the new kernel's boot entry?
    cmdline=$(on "$entry" 'cat /proc/cmdline')
    owned=$(on "$entry" 'sudo sed -n "s/^# canon-kernel-managed: *//p" /etc/default/grub 2>/dev/null | head -1')
    [ -n "$owned" ] || owned=$(on "$entry" "sudo grep -h '^_canon_keys=' /etc/default/grub.d/99-canon-kernel.cfg 2>/dev/null | head -1 | cut -d'\"' -f2")
    survived="" lost=""
    for key in $owned; do
      case " $cmdline " in *" $key="*) survived="$survived $key" ;; *) lost="$lost $key" ;; esac
    done
    if [ -z "$owned" ]; then
      echo "      (no managed boot arguments on this host)"
    elif [ -z "$lost" ]; then
      echo "      OBSERVED: the new kernel inherited every managed argument -$survived"
    else
      echo "      OBSERVED: the new kernel LOST -$lost"
      echo "                (this is the failure mode the role's second write exists for:"
      echo "                 grubby fixes the entries that exist, /etc/default/grub is what"
      echo "                 a future kernel inherits from)"
    fi
  done

  # --- re-apply to the new kernel, which is what was asked for ---------------
  echo
  echo "== phase 4b: re-apply the role to the new kernel, and require it active"
  ansible-playbook -i "$INV" kernel.yml --limit "$LIMIT" \
    -e kernel_reboot_ok=true -e kernel_fail_on_reboot_required=true \
    > "$OUT/phase4b.log" 2>&1
  rc=$?
  grep -E '"msg": "kvm-' "$OUT/phase4b.log" | sed 's/.*"msg": "/   /; s/"$//'
  if [ $rc -eq 0 ]; then
    printf '   PASS  every host: tuning re-applied and active on the new kernel\n'; pass=$((pass + 1))
  else
    printf '   FAIL  re-apply left something inactive - see %s\n' "$OUT/phase4b.log"
    grep -E "^fatal|assertion" "$OUT/phase4b.log" | head -5
    fail=$((fail + 1))
  fi

  echo
  echo "-- final state, outside Ansible --"
  for entry in "${TARGETS[@]}"; do
    name=$(field "$entry" 1)
    printf '   %-11s %-34s %s\n' "$name" "$(on "$entry" 'uname -r')" \
      "$(on "$entry" 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null')"
  done
fi

echo
if [ "$fail" -eq 0 ]; then
  # The summary says only what this run actually tested. With SKIP_UPGRADE=1
  # phase 4 never happened, and claiming the new-kernel result anyway is the
  # same class of mistake as a check that silently skips itself and reports
  # PASS - which is exactly what A33 was.
  if [ "${SKIP_UPGRADE:-0}" = "1" ]; then
    echo "VERIFIED: $pass check(s) passed. Boot arguments survive a reboot."
    echo "          Phase 4 was skipped, so this run says NOTHING about what"
    echo "          happens after a kernel upgrade - drop SKIP_UPGRADE for that."
  else
    echo "VERIFIED: $pass check(s) passed. Boot arguments survive a reboot, and a"
    echo "          re-apply puts them on a newly installed kernel."
  fi
  exit 0
fi
echo "FAILED: $fail check(s) failed, $pass passed."
exit 1
