#!/usr/bin/env bash
# Remove the lab containers. Reports and drift history on the host are kept.
set -euo pipefail
ids="$(docker ps -aq --filter name=lab-)"
[ -n "$ids" ] && docker rm -f $ids >/dev/null
echo "lab hosts removed"
