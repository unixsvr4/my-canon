#!/usr/bin/env bash
# =============================================================================
# Four REAL virtual machines, each with its own kernel, so a reboot is a reboot.
#
#   ./vms/up.sh                 create and boot all four
#   ./vms/up.sh kvm-rhel        just one
#   ./vms/down.sh               shut them down
#   ./vms/down.sh --clean       ...and delete the disks (keeps the base images)
#
# WHY THIS EXISTS, ON TOP OF THE CONTAINERS
#
# The container lab (setup-distros.sh) proves the role writes the right file in
# the right place on four distributions. It cannot prove the thing the setting
# is FOR, because a container has no kernel of its own and cannot reboot:
# `/proc/cmdline` inside it is the host's, and the boot arguments the role
# configures are reported as "pending" forever.
#
# These are QEMU guests booting real distribution cloud images under macOS's
# Hypervisor.framework. They have their own kernel, their own bootloader, and
# `reboot` means what it says - so "it survives a reboot" becomes something you
# watch happen rather than something the README claims.
#
# Cost: nothing. The images are the distributions' own public cloud images.
# Time: a few minutes per VM on first boot, mostly cloud-init.
#
# THE IMAGES ARE DELIBERATELY OLD (AlmaLinux 9.4, Ubuntu 24.04 GA, Amazon Linux
# 2023.4 - all from early 2024). A current image has nothing to upgrade, and the
# second half of the test needs a REAL kernel upgrade to boot into.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

VM_DIR="${VM_DIR:-/tmp/canon-kernel-vms}"
FW="$(brew --prefix qemu 2>/dev/null)/share/qemu/edk2-aarch64-code.fd"
KEY="$VM_DIR/id_ed25519"
ARCH="$(uname -m)"

# name | image | ssh port | MiB | url
#
# kvm-rhel gets 4GB rather than 2GB because its profile reserves a 1GB huge
# page at boot, and a 2GB guest cannot find one contiguously - the argument
# ends up active with zero pages reserved, which the verifier now catches.
#
# The distribution FAMILIES are what matter, and these are the free, publicly
# downloadable images for each: AlmaLinux for RHEL 9 (bit-for-bit rebuild),
# openSUSE Leap for SLES 15 (same GRUB mechanism, same os_family "Suse"), and
# Amazon Linux 2023 and Ubuntu 24.04 as themselves.
VMS=(
  "kvm-rhel   | alma   | 2231 | 4096 | https://repo.almalinux.org/vault/9.4/cloud/aarch64/images/AlmaLinux-9-GenericCloud-9.4-20240507.aarch64.qcow2"
  "kvm-ubuntu | ubuntu | 2232 | 2048 | https://cloud-images.ubuntu.com/releases/24.04/release-20240423/ubuntu-24.04-server-cloudimg-arm64.img"
  "kvm-suse   | suse   | 2233 | 2048 | https://download.opensuse.org/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.aarch64-Cloud.qcow2"
  "kvm-amazon | amazon | 2234 | 2560 | https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/al2023-kvm-2023.12.20260917.1-kernel-6.1-arm64.xfs.gpt.qcow2"
)

field() { printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/^ *//; s/ *$//'; }

if [ "$ARCH" != "arm64" ]; then
  echo "[ERROR] These image URLs are aarch64 (Apple Silicon). On x86_64, swap them"
  echo "        for the x86_64 equivalents and use edk2-x86_64-code.fd."
  exit 2
fi
[ -f "$FW" ] || { echo "[ERROR] UEFI firmware not found at $FW - brew install qemu"; exit 2; }

mkdir -p "$VM_DIR/images" "$VM_DIR/run"

# One key for the lab, generated locally, never committed. The VMs are
# throwaway; the point is that no password authentication is ever enabled.
if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'canon-kernel-vm-lab' -f "$KEY"
  echo "generated $KEY"
fi
PUBKEY="$(cat "$KEY.pub")"

boot_one() {
  local name="$1" image="$2" port="$3" mem="$4" url="$5"
  local base="$VM_DIR/images/$image.qcow2"
  local disk="$VM_DIR/run/$name.qcow2"
  local seed="$VM_DIR/run/$name-seed.iso"
  local pidfile="$VM_DIR/run/$name.pid"

  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "$name already running (pid $(cat "$pidfile"))"
    return 0
  fi

  if [ ! -s "$base" ]; then
    echo "downloading $image ..."
    curl -fsSL --retry 3 -o "$base.part" "$url" && mv "$base.part" "$base"
  fi

  # A qcow2 overlay, so the base image stays pristine and `down.sh --clean`
  # is instant. Every test run starts from the same bytes.
  #
  # THE SIZE MUST BE AT LEAST THE BACKING FILE'S VIRTUAL SIZE.
  #
  # This was a hard-coded 20G, and Amazon Linux 2023's image is 25G. qemu-img
  # accepts the smaller overlay without complaint and the guest then sees a
  # TRUNCATED disk: grub and the kernel live near the start and load fine, the
  # root partition is past the end and cannot be mounted, and the guest stalls
  # after one early kernel message with nothing useful on the console. Two of
  # the four images are larger than 20G, so the bug looked like "Amazon Linux
  # does not boot under QEMU" for a while (RESEARCH.md A29).
  #
  # Created with NO SIZE, which makes it inherit the backing file's virtual
  # size exactly - then grown to 20G for the kernel installs later. The grow
  # is a no-op (and refused, harmlessly) on an image that is already bigger.
  # An earlier version parsed the size out of `qemu-img info` and got it
  # wrong, which is the same bug again with more code.
  if [ ! -f "$disk" ]; then
    qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$disk"
    qemu-img resize -q "$disk" 20G 2>/dev/null || true
  fi

  # --- cloud-init NoCloud seed ----------------------------------------------
  #
  # The same mechanism as lab 3's rendered user data, and as minimal for the
  # same reason: it creates the login the controller needs and installs a
  # Python interpreter, then gets out of the way. Everything that has to STAY
  # correct is Ansible's job.
  if [ ! -f "$seed" ]; then
    local seeddir="$VM_DIR/run/$name-seed"
    rm -rf "$seeddir"; mkdir -p "$seeddir"

    cat > "$seeddir/meta-data" <<EOF
instance-id: $name
local-hostname: $name
EOF
    cat > "$seeddir/user-data" <<EOF
#cloud-config
hostname: $name
preserve_hostname: false

users:
  - name: canon
    groups: [wheel, sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $PUBKEY

ssh_pwauth: false
disable_root: true

# No package upgrades here. The kernel upgrade later in the test is a
# deliberate, observed step - not something that happens on first boot and
# makes two VMs different depending on when they were created.
package_update: false
package_upgrade: false

runcmd:
  - [sh, -c, 'echo canon-vm-ready > /run/canon-ready']
EOF
    # cloud-init's NoCloud datasource looks for a filesystem labelled `cidata`.
    hdiutil makehybrid -quiet -iso -joliet \
      -iso-volume-name cidata -joliet-volume-name cidata \
      -o "$seed" "$seeddir" >/dev/null
  fi

  # --- boot ------------------------------------------------------------------
  #
  # -accel hvf: Hypervisor.framework, so this is virtualisation and not
  # emulation - the guest runs at native speed on Apple Silicon.
  #
  # gic-version=max: QEMU's `virt` machine still defaults to GICv2 for
  # compatibility with old guests, and Amazon Linux 2023's arm64 kernel wants
  # GICv3. Without it that guest never reaches userspace.
  # User-mode networking with a forwarded port keeps the whole lab inside one
  # process: no bridge, no sudo, no host network changes.
  qemu-system-aarch64 \
    -name "$name" \
    -machine virt,gic-version=max -accel hvf -cpu host -smp 2 -m "$mem" \
    -bios "$FW" \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -drive "file=$seed,if=virtio,format=raw,media=cdrom" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-rng-pci \
    -display none \
    -serial "file:$VM_DIR/run/$name-console.log" \
    -pidfile "$pidfile" \
    -daemonize

  printf 'booting %-11s port %s  ' "$name" "$port"
}

# The interpreter Ansible needs, installed explicitly and verified.
#
# This was a cloud-init `runcmd` first, and it was the wrong place twice over:
# cloud-init runs it in the FINAL stage, long after sshd is up, so a play could
# start before it finished; and when the install failed, cloud-init carried on
# to the next command and the readiness sentinel was written anyway. A
# readiness signal that fires whether the work succeeded or not is worse than
# none.
#
# So it happens here, in the open, with the result checked - exactly as
# setup-distros.sh does it for the containers.
#
# SLES/openSUSE Leap 15's own python3 is 3.6, which ansible-core cannot run its
# modules on (RESEARCH.md A18), which is why that one needs anything at all.
ensure_interpreter() {
  local name="$1" port="$2" image="$3"
  local interp cmd
  case "$image" in
    suse)   interp=/usr/bin/python3.11 ; cmd='sudo zypper --non-interactive --gpg-auto-import-keys install -y python311' ;;
    ubuntu) interp=/usr/bin/python3    ; cmd='sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3' ;;
    *)      interp=/usr/bin/python3    ; cmd='sudo dnf -y -q install python3' ;;
  esac

  if remote "$port" "test -x $interp"; then
    return 0
  fi
  printf ' installing %s' "$(basename "$interp")"
  # Two attempts: the first repo refresh over slirp NAT is slow and sometimes
  # times out, and a retry is cheaper than failing the whole lab.
  remote "$port" "$cmd" >/dev/null 2>&1 || remote "$port" "$cmd" >/dev/null 2>&1 || true
  if remote "$port" "test -x $interp"; then
    return 0
  fi
  echo " FAILED"
  echo "       $interp is still missing on $name - the play would fail with"
  echo "       \"The module interpreter '$interp' was not found\""
  return 1
}

remote() {
  local port="$1"; shift
  ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -i "$KEY" -p "$port" canon@127.0.0.1 "$@" 2>/dev/null
}

# sshd answering is NOT "the machine is ready".
#
# cloud-init starts sshd and THEN runs its `runcmd` steps, so there is a window
# in which you can log in and the interpreter Ansible needs is not installed
# yet. Waiting only for ssh made the SUSE host fail its very first play with
# "The module interpreter '/usr/bin/python3.11' was not found" - the install
# was still running.
#
# So the wait is for the SENTINEL that the seed writes as its LAST runcmd step,
# which is the same idea as the health gate in patch.yml: wait for the thing
# that means "finished", not for the first sign of life.
wait_ready() {
  local name="$1" port="$2" tries=0
  local ssh_ok=0
  while [ $tries -lt 200 ]; do
    if [ $ssh_ok -eq 0 ]; then
      if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
             -i "$KEY" -p "$port" canon@127.0.0.1 true 2>/dev/null; then
        ssh_ok=1
        printf 'ssh'
      fi
    else
      if remote "$port" 'test -f /run/canon-ready'; then
        printf ' + cloud-init'
        return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 3
    [ $((tries % 10)) -eq 0 ] && printf '.'
  done
  echo "TIMED OUT"
  echo "       console:    $VM_DIR/run/$name-console.log"
  echo "       ssh worked: $ssh_ok (0 means it never came up; 1 means cloud-init never finished)"
  return 1
}

WANTED=("$@")
started=()
for entry in "${VMS[@]}"; do
  name=$(field "$entry" 1)
  if [ ${#WANTED[@]} -gt 0 ]; then
    case " ${WANTED[*]} " in *" $name "*) ;; *) continue ;; esac
  fi
  boot_one "$name" "$(field "$entry" 2)" "$(field "$entry" 3)" "$(field "$entry" 4)" "$(field "$entry" 5)"
  started+=("$name:$(field "$entry" 3)")
done

# Wait after starting them all, so the four boots overlap instead of queueing.
rc=0
for s in "${started[@]}"; do
  name="${s%%:*}"
  image=""
  for entry in "${VMS[@]}"; do
    [ "$(field "$entry" 1)" = "$name" ] && image="$(field "$entry" 2)"
  done
  if wait_ready "$name" "${s##*:}"; then
    ensure_interpreter "$name" "${s##*:}" "$image" && echo " + interpreter ok" || rc=1
  else
    rc=1
  fi
done

echo
printf '%-12s %-6s %s\n' NAME PORT KERNEL
for s in "${started[@]}"; do
  name="${s%%:*}"; port="${s##*:}"
  k=$(ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$KEY" -p "$port" canon@127.0.0.1 'uname -r; . /etc/os-release; echo "$PRETTY_NAME"' 2>/dev/null | paste -sd' ' -)
  printf '%-12s %-6s %s\n' "$name" "$port" "${k:-unreachable}"
done

echo
echo "inventory: inventory/kernel-vms.yml   (VM_DIR=$VM_DIR)"
exit $rc
