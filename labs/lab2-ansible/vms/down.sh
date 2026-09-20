#!/usr/bin/env bash
# =============================================================================
# Shut the kernel-lab VMs down.
#
#   ./vms/down.sh                    shut them all down, keep the disks (a re-up is instant)
#   ./vms/down.sh kvm-rhel           shut just that one down
#   ./vms/down.sh --clean            ...and delete the disks and seeds
#   ./vms/down.sh --clean kvm-suse   ...for one of them
#   ./vms/down.sh --purge            ...and the downloaded base images too (about 3GB)
#
# Taking one name is the other half of `./vms/up.sh kvm-rhel`. The four guests
# ask for about 10.7GB between them, so the one-at-a-time path is the usable
# one on a 16GB laptop - and it only works if you can give the memory back
# without stopping the other three.
#
# Nothing here touches anything outside $VM_DIR (default /tmp/canon-kernel-vms),
# and /tmp is cleared on reboot anyway - so the worst case for forgetting to run
# this is four idle QEMU processes.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

VM_DIR="${VM_DIR:-/tmp/canon-kernel-vms}"
ALL=(kvm-rhel kvm-ubuntu kvm-suse kvm-amazon)

MODE=""
NAMES=()
for arg in "$@"; do
  case "$arg" in
    --clean|--purge) MODE="$arg" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg"; exit 2 ;;
    *) NAMES+=("$arg") ;;
  esac
done

if [ ${#NAMES[@]} -eq 0 ]; then
  NAMES=("${ALL[@]}")
else
  for n in "${NAMES[@]}"; do
    case " ${ALL[*]} " in
      *" $n "*) ;;
      *) echo "unknown VM: $n (known: ${ALL[*]})"; exit 2 ;;
    esac
  done
fi

for name in "${NAMES[@]}"; do
  pidfile="$VM_DIR/run/$name.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    # ACPI would be politer, but these are throwaway guests with nothing to
    # flush and the point is to get the host's cores and memory back.
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

if [ "$MODE" = "--clean" ] || [ "$MODE" = "--purge" ]; then
  echo "removed the per-VM disks and seeds for: ${NAMES[*]}"
fi

if [ "$MODE" = "--purge" ]; then
  # The base images are shared between runs and are the expensive thing to
  # re-download, so a partial purge leaves them alone rather than deleting an
  # image another VM is still overlaying.
  if [ ${#NAMES[@]} -eq ${#ALL[@]} ]; then
    rm -rf "$VM_DIR/images"
    echo "removed the downloaded base images"
  else
    echo "kept the base images: purging a subset would delete images the other VMs share"
    echo "run ./vms/down.sh --purge with no names to remove them"
  fi
fi

remaining=$(du -sh "$VM_DIR" 2>/dev/null | cut -f1)
[ -n "$remaining" ] && echo "left in $VM_DIR: $remaining"
exit 0
