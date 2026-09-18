#!/usr/bin/env bash
# =============================================================================
# Create the four distribution containers for the kernel role's lab.
#
#   ./setup-distros.sh          create them
#   ./setup-distros.sh --down   remove them
#
# They stand in for four real hosts. Only python3 is installed, because the
# kernel role installs no packages by design - the baseline role owns
# packages, and a tuning role that pulls in a package manager is a tuning role
# nobody can reason about.
#
# Why a Python install is needed at all: Ansible modules are Python, and
# ubuntu:24.04 ships without an interpreter. On a real host the image build or
# cloud-init has already done this; here the equivalent bootstrap is explicit,
# and kernel.yml's pre_task fails with a readable message if it was skipped.
#
# SLES 15 is the interesting one: it DOES ship python3, and it is 3.6.15, which
# ansible-core cannot use as a target interpreter - every module fails with
# "SyntaxError: future feature annotations is not defined", because
# `from __future__ import annotations` needs 3.7+. So the package to install is
# python311, and the inventory pins ansible_python_interpreter to it. An
# ancient system Python that cannot be removed (SUSE's own tooling depends on
# it) alongside a modern one is the normal state of a long-lived enterprise
# distribution, and the interpreter has to be chosen explicitly rather than
# discovered.
#
# Images (all free to pull, no subscription):
#   almalinux:9                      RHEL 9 rebuild - the RHEL family
#   ubuntu:24.04                     the Debian family
#   registry.suse.com/bci/bci-base   SUSE's own SLE 15 base image
#   amazonlinux:2023                 Amazon Linux 2023
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# name | image | interpreter that must exist | how to install it
#
# Pipe-separated, not colon-separated: a registry path contains colons of its
# own (registry.suse.com/bci/bci-base:15.6) and splitting on them is how you
# end up pulling "registry.suse.com/bci/bci-base".
HOSTS=(
  "ktr-rhel   | almalinux:9                          | /usr/bin/python3      | dnf -y -q install python3"
  "ktr-ubuntu | ubuntu:24.04                         | /usr/bin/python3      | apt-get update -qq && apt-get install -y -qq python3"
  "ktr-suse   | registry.suse.com/bci/bci-base:15.6  | /usr/bin/python3.11   | zypper -n -q install python311"
  "ktr-amazon | amazonlinux:2023                     | /usr/bin/python3      | dnf -y -q install python3"
)

field() { printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/^ *//; s/ *$//'; }

if [ "${1:-}" = "--down" ]; then
  for entry in "${HOSTS[@]}"; do
    name=$(field "$entry" 1)
    docker rm -f "lab-$name" >/dev/null 2>&1 || true
    echo "removed lab-$name"
  done
  exit 0
fi

if [ ! -d collections/ansible_collections/community/docker ]; then
  echo "installing pinned collections into ./collections"
  ansible-galaxy collection install -r requirements.yml -p ./collections >/dev/null
fi

for entry in "${HOSTS[@]}"; do
  name=$(field "$entry" 1)
  image=$(field "$entry" 2)
  interpreter=$(field "$entry" 3)
  install_cmd=$(field "$entry" 4)

  docker pull -q "$image" >/dev/null
  docker rm -f "lab-$name" >/dev/null 2>&1 || true

  # --hostname matches the inventory name, the same contract patch.yml's
  # pre-flight asserts. No --privileged: these containers deliberately cannot
  # load modules or write /proc/sys, which is what makes the role's
  # "configured but not running" reporting visible instead of theoretical.
  docker run -d --name "lab-$name" --hostname "$name" "$image" sleep infinity >/dev/null

  # Test for the EXACT interpreter the inventory pins, not for "a python3".
  # SLES ships /usr/bin/python3 as 3.6, so `command -v python3` succeeds and
  # every Ansible module then fails on it.
  if ! docker exec "lab-$name" test -x "$interpreter"; then
    echo "installing $interpreter in lab-$name ($image)"
    docker exec "lab-$name" sh -c "$install_cmd" >/dev/null 2>&1 ||
      { echo "ERROR: could not install $interpreter in lab-$name"; exit 1; }
    docker exec "lab-$name" test -x "$interpreter" ||
      { echo "ERROR: $interpreter still missing in lab-$name"; exit 1; }
  fi

  printf 'started lab-%-12s %-38s %s\n' "$name" "$image" "$(docker exec "lab-$name" "$interpreter" -V 2>&1)"
done

echo
docker ps --filter name=lab-ktr- --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
