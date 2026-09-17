#!/usr/bin/env bash
# Simulate three out-of-band changes to a LIVE environment, for verify-env.py.
#
#   ./tamper-env.sh envs/prod
#
# Each one is something a successful `terraform apply` would never tell you:
#
#   1. hand-scale api to 1 replica      -> integrity + prod replica policy
#                                          (terraform plan sees this; apply fixes it)
#   2. create an object nobody manages  -> unmanaged
#                                          (plan can't see it; apply won't remove it)
#   3. make the datastore world-writable -> integrity (permission)
#                                          (plan can't see it; apply won't fix it)
#
# 2 and 3 are the reason a post-apply verification exists at all: they are
# invisible to Terraform's own drift detection. See the Lab 1 README, Exercise B.
set -euo pipefail

ROOT="${1:-envs/prod}"
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
ART="$LAB_DIR/$ROOT/.artifacts"
PREFIX="canon-$(basename "$ROOT")"

[ -f "$ART/$PREFIX-api.json" ] || { echo "[ERROR] $ROOT is not applied (no $PREFIX-api.json)"; exit 1; }

# 1. jsonencode writes compact JSON, so the field is exactly "desired_count":N
perl -pi -e 's/"desired_count":\d+/"desired_count":1/' "$ART/$PREFIX-api.json"
grep -q '"desired_count":1' "$ART/$PREFIX-api.json"
echo "[TAMPERED] $ROOT: api hand-scaled to 1 replica"

# 2.
echo '{"name":"'"$PREFIX"'-hotfix","created_by":"a human, at 3am"}' > "$ART/$PREFIX-hotfix.json"
echo "[TAMPERED] $ROOT: unmanaged object $PREFIX-hotfix.json created"

# 3.
chmod 0666 "$ART/$PREFIX-datastore.json"
echo "[TAMPERED] $ROOT: datastore permissions set to 0666"
