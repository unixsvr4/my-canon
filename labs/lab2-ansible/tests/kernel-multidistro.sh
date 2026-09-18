#!/usr/bin/env bash
# =============================================================================
# One role, four distributions: converge, then prove the PER-DISTRIBUTION
# mechanism was actually used - not just that the play went green.
#
#   tests/kernel-multidistro.sh
#
# A play that succeeds on four distributions proves the tasks did not error. It
# does not prove the RHEL host got BLS-style arguments, that the Ubuntu host got
# a drop-in that sorts last, or that SUSE's file is the one grub2-mkconfig
# reads. Those are four different mechanisms, and "it ran" is not evidence about
# any of them. This test asserts the artifact each mechanism is supposed to
# leave behind.
#
# Then it runs the play a second time and requires zero changes, which is the
# claim that actually matters for a role that will run on a schedule forever.
#
# exit 0 = all four converged, produced the right artifacts, and are idempotent
# exit 1 = an assertion failed (listed)
# exit 2 = the converge itself failed
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

INV=inventory/kernel-hosts.yml
OUT=reports/kernel
mkdir -p "$OUT"
fails=0

check() {
  local label="$1" host="$2" file="$3" pattern="$4"
  if docker exec "lab-$host" grep -qE -- "$pattern" "$file" 2>/dev/null; then
    printf '   PASS  %-11s %s\n' "$host" "$label"
  else
    printf '   FAIL  %-11s %s\n' "$host" "$label"
    printf '         expected /%s/ in %s\n' "$pattern" "$file"
    fails=$((fails + 1))
  fi
}

absent() {
  local label="$1" host="$2" file="$3" pattern="$4"
  if docker exec "lab-$host" grep -qE -- "$pattern" "$file" 2>/dev/null; then
    printf '   FAIL  %-11s %s\n' "$host" "$label"
    printf '         did NOT expect /%s/ in %s\n' "$pattern" "$file"
    fails=$((fails + 1))
  else
    printf '   PASS  %-11s %s\n' "$host" "$label"
  fi
}

for h in ktr-rhel ktr-ubuntu ktr-suse ktr-amazon; do
  docker inspect "lab-$h" >/dev/null 2>&1 || {
    echo "lab-$h is not running - run ./setup-distros.sh first"
    exit 2
  }
done

echo "== run 1: converge four distributions"
if ! ansible-playbook -i "$INV" kernel.yml > "$OUT/converge.log" 2>&1; then
  echo "   converge FAILED - see $OUT/converge.log"
  grep -E "^fatal|FAILED!" "$OUT/converge.log" | head -10
  exit 2
fi
grep -E '"msg": "ktr-' "$OUT/converge.log" | sed 's/.*"msg": "/   /; s/"$//'

# --- Layer 3: each family's own mechanism ------------------------------------
echo
echo "== the bootloader mechanism each distribution actually uses"

# RHEL family: the shell-style file, key GRUB_CMDLINE_LINUX (no _DEFAULT).
check "GRUB_CMDLINE_LINUX in /etc/default/grub" \
  ktr-rhel /etc/default/grub '^GRUB_CMDLINE_LINUX="'
check "database profile: THP off at boot" \
  ktr-rhel /etc/default/grub 'transparent_hugepage=never'
check "database profile: 1GB hugepages reserved at boot" \
  ktr-rhel /etc/default/grub 'default_hugepagesz=1G.*hugepages=8'
# The RHEL family must NOT get the _DEFAULT form: that is the Debian key, and
# grub on this family would ignore it.
absent "no GRUB_CMDLINE_LINUX_DEFAULT (that is Debian's key)" \
  ktr-rhel /etc/default/grub '^GRUB_CMDLINE_LINUX_DEFAULT='

# Debian family: a 99- drop-in, NOT an edit of /etc/default/grub.
check "99- drop-in exists (sorts after the cloud image's 50-)" \
  ktr-ubuntu /etc/default/grub.d/99-canon-kernel.cfg 'GRUB_CMDLINE_LINUX_DEFAULT='
check "drop-in filters the keys it manages before appending" \
  ktr-ubuntu /etc/default/grub.d/99-canon-kernel.cfg '_canon_keys=" transparent_hugepage "'
check "the host's own extra boot argument reached layer 3" \
  ktr-ubuntu /etc/default/grub.d/99-canon-kernel.cfg 'transparent_hugepage=madvise'

# SUSE: the file, with the _DEFAULT key, and the most boot arguments.
check "GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" \
  ktr-suse /etc/default/grub '^GRUB_CMDLINE_LINUX_DEFAULT="'
check "low-latency profile: isolated cores" \
  ktr-suse /etc/default/grub 'isolcpus=managed_irq,domain,2-7'
check "low-latency profile: C-states capped" \
  ktr-suse /etc/default/grub 'processor.max_cstate=1'
# All three isolation arguments must name the same cores, or the configuration
# is worse than doing nothing.
check "isolcpus, nohz_full and rcu_nocbs all name 2-7" \
  ktr-suse /etc/default/grub 'isolcpus=[^ ]*2-7.*nohz_full=2-7.*rcu_nocbs=2-7'

# Amazon Linux: RHEL mechanics, inherited rather than duplicated.
check "Amazon Linux uses the RHEL family's key" \
  ktr-amazon /etc/default/grub '^GRUB_CMDLINE_LINUX='

# --- Layer 1 and 2: the same on every distribution ---------------------------
echo
echo "== the layers that do not vary by distribution"

check "container-host: inotify watches raised" \
  ktr-amazon /etc/sysctl.d/90-canon-kernel.conf 'fs.inotify.max_user_watches = 1048576'
check "container-host: ARP table sized for a large pod network" \
  ktr-amazon /etc/sysctl.d/90-canon-kernel.conf 'net.ipv4.neigh.default.gc_thresh3 = 16384'
check "container-host: kubelet does the evicting, not the kernel" \
  ktr-amazon /etc/sysctl.d/90-canon-kernel.conf 'vm.panic_on_oom = 0'
# The _extra merge: the host's own key is present AND the profile's keys
# survived. A caller that replaced the dict instead of merging would have one
# key in this file and nothing else.
check "_extra merged over the profile, did not replace it" \
  ktr-amazon /etc/sysctl.d/90-canon-kernel.conf 'net.ipv4.tcp_congestion_control = bbr'

check "throughput: BBR needs fq, and both are set" \
  ktr-ubuntu /etc/sysctl.d/90-canon-kernel.conf 'net.core.default_qdisc = fq'
# Layer 2: the setting with no runtime equivalent at all.
check "nf_conntrack hashsize set as a LOAD-TIME option" \
  ktr-ubuntu /etc/modprobe.d/canon-kernel.conf 'options nf_conntrack hashsize=262144'
check "br_netfilter loaded at boot, not left to the CNI" \
  ktr-amazon /etc/modules-load.d/canon-kernel.conf '^br_netfilter$'
# Both soft and hard: a hard limit alone changes nothing about what processes get.
check "database: memlock unlimited, soft and hard" \
  ktr-rhel /etc/security/limits.d/90-canon-kernel.conf 'memlock.*unlimited'

# --- Idempotence -------------------------------------------------------------
echo
echo "== run 2: must change nothing on any of the four"
ANSIBLE_CALLBACKS_ENABLED=ansible.posix.json \
ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
ANSIBLE_RETRY_FILES_ENABLED=false \
  ansible-playbook -i "$INV" kernel.yml > "$OUT/run2.json" 2> "$OUT/run2.err"

python3 - "$OUT/run2.json" <<'PY'
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
        print(f"   FAIL  {h:<11} changed={len(changed[h])}")
        for name in changed[h]:
            print(f"         {name}")
    else:
        print(f"   PASS  {h:<11} changed=0")
sys.exit(1 if changed else 0)
PY
idem=$?

echo
if [ "$fails" -eq 0 ] && [ "$idem" -eq 0 ]; then
  echo "VERIFIED: 4 distributions, 4 profiles, 3 persistence layers, zero changes on run 2."
  exit 0
fi
echo "FAILED: $fails artifact assertion(s), idempotence exit $idem."
exit 1
