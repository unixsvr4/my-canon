#!/usr/bin/env bash
# =============================================================================
# Shut the kernel-lab VMs down.
#
#   ./vms/down.sh            shut them down, keep the disks (a re-up is instant)
#   ./vms/down.sh --clean    ...and delete the disks and seeds
#   ./vms/down.sh --purge    ...and the downloaded base images too (~3GB)
#
# Nothing here touches anything outside $VM_DIR (default /tmp/canon-kernel-vms),
# and /tmp is cleared on reboot anyway - so the worst case for forgetting to run
# this is four idle QEMU processes.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

VM_DIR="${VM_DIR:-/tmp/canon-kernel-vms}"
MODE="${1:-}"
NAMES=(kvm-rhel kvm-ubuntu kvm-suse kvm-amazon)

for name in "${NAMES[@]}"; do
  pidfile="$VM_DIR/run/$name.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    # ACPI would be politer, but these are throwaway guests with nothing to
    # flush and the point is to get the host's cores back.
    kill "$(cat "$pidfile")" 2>/dev/null
    printf 'stopped %s\n' "$name"
  else
    printf 'not running %s\n' "$name"
  fi
  rm -f "$pidfile"

  if [ "$MODE" = "--clean" ] || [ "$MODE" = "--purge" ]; then
    rm -rf "$VM_DIR/run/$name.qcow2" "$VM_DIR/run/$name-seed.iso" \
           "$VM_DIR/run/$name-seed" "$VM_DIR/run/$name-console.log"
  fi
done

if [ "$MODE" = "--purge" ]; then
  rm -rf "$VM_DIR/images"
  echo "removed the downloaded base images"
fi

if [ "$MODE" = "--clean" ] || [ "$MODE" = "--purge" ]; then
  echo "removed the per-VM disks and seeds"
fi

remaining=$(du -sh "$VM_DIR" 2>/dev/null | cut -f1)
[ -n "$remaining" ] && echo "left in $VM_DIR: $remaining"
exit 0
