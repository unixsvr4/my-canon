#!/usr/bin/env bash
# =============================================================================
# Create six throwaway "servers" as containers, and install the pinned
# collections. No SSH keys, no VMs, no cost. Safe to re-run: it recreates the
# containers from scratch.
#
# The containers stand in for physical or virtual hosts. The playbooks, the
# role and the rollout logic are identical either way; only the connection
# settings in inventory/group_vars/all.yml would change.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=almalinux:9
HOSTS=(web01 web02 web03 db01 db02 app01)

if [ ! -d collections/ansible_collections/community/docker ]; then
  echo "installing pinned collections into ./collections"
  ansible-galaxy collection install -r requirements.yml -p ./collections >/dev/null
fi

docker pull -q "$IMAGE" >/dev/null
for h in "${HOSTS[@]}"; do
  docker rm -f "lab-$h" >/dev/null 2>&1 || true
  # --hostname matches the inventory name: patch.yml's pre-flight asserts it.
  docker run -d --name "lab-$h" --hostname "$h" "$IMAGE" sleep infinity >/dev/null
  echo "started lab-$h"
done
mkdir -p reports
echo
docker ps --filter name=lab- --format 'table {{.Names}}\t{{.Status}}'
