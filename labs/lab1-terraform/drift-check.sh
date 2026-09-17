#!/usr/bin/env bash
# Drift detection exactly as it runs in production, minus the ticket creation.
#   exit 0 = no changes    exit 1 = error    exit 2 = DRIFT
#
#   ./drift-check.sh envs/dev              # check; archive the drift; drop the binary plan
#   KEEP_PLAN=1 ./drift-check.sh envs/dev  # also leave drift.tfplan in the env dir
#   ARCHIVE=0   ./drift-check.sh envs/dev  # check only, write nothing
#
# THE ARCHIVE IS THE POINT. Every run that finds drift writes a timestamped,
# immutable record under drift-history/ and appends a row to
# drift-history/index.csv. Applying the code afterwards fixes the environment
# but does NOT erase the evidence - which is what you need in a regulated shop
# to answer "what changed, when did we notice, and how long was it that way".
# A drift report that disappears the moment you remediate can't answer any of
# those questions.
#
# What gets archived, and why it differs from the working plan:
#   plan.txt  + plan.json  -> the record. Text for a human/ticket, JSON for a
#                             policy gate (conftest / OPA / tfsec / Checkov).
#   plan.tfplan            -> ONLY with KEEP_PLAN=1. The binary plan is valid
#                             only against the state serial that produced it and
#                             carries every attribute in the clear, so it is a
#                             short-retention pipeline artifact, never a
#                             long-lived record.
set -uo pipefail

ROOT="${1:-envs/dev}"
KEEP_PLAN="${KEEP_PLAN:-0}"
ARCHIVE="${ARCHIVE:-1}"

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
HISTORY_DIR="$LAB_DIR/drift-history"
INDEX="$HISTORY_DIR/index.csv"

cd "$LAB_DIR/$ROOT" || exit 1

terraform init -input=false -no-color >/dev/null || exit 1
terraform plan -detailed-exitcode -no-color -out=drift.tfplan
rc=$?

case $rc in
  0) echo "[OK]    $ROOT: no drift" ;;
  2) echo "[DRIFT] $ROOT: infrastructure does not match code"
     echo "----- diff -----"
     terraform show -no-color drift.tfplan ;;
  *) echo "[ERROR] $ROOT: plan failed" ;;
esac

# --- archive -------------------------------------------------------------
if [ "$ARCHIVE" = "1" ] && [ $rc -eq 2 ]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  slug="$(echo "$ROOT" | tr '/' '-')"
  dest="$HISTORY_DIR/$slug/$stamp"
  suffix=2
  # Two runs in the same second must not collide: the first record is
  # read-only, so writing over it would fail and silently lose the second.
  while [ -e "$dest" ]; do dest="$HISTORY_DIR/$slug/$stamp-$suffix"; suffix=$((suffix + 1)); done
  stamp="$(basename "$dest")"
  mkdir -p "$dest"

  terraform show -no-color drift.tfplan > "$dest/plan.txt"
  terraform show -json     drift.tfplan > "$dest/plan.json"
  [ "$KEEP_PLAN" = "1" ] && cp drift.tfplan "$dest/plan.tfplan"

  # Which resources, and what action - the line a ticket actually needs.
  changed="$(python3 - "$dest/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
rows = [(rc["address"], "+".join(rc["change"]["actions"]))
        for rc in plan.get("resource_changes", [])
        if rc["change"]["actions"] != ["no-op"]]
# Resource addresses contain double quotes (for_each keys: service["api"]), so
# double them for the RFC 4180 quoted field the caller wraps this in.
print(";".join(f"{a}={act}" for a, act in rows).replace('"', '""'))
PY
)"
  n="$(echo "$changed" | tr ';' '\n' | grep -c . || true)"

  # Read-only once written: the record must not be quietly edited later.
  chmod -w "$dest"/* 2>/dev/null

  [ -f "$INDEX" ] || echo "detected_utc,root,exit_code,changed_count,changed_resources,record" > "$INDEX"
  echo "$stamp,$ROOT,$rc,$n,\"$changed\",drift-history/$slug/$stamp" >> "$INDEX"

  echo "[ARCHIVED] $n drifted resource(s) -> drift-history/$slug/$stamp"
  echo "[ARCHIVED] index: drift-history/index.csv"
fi

# --- working copy --------------------------------------------------------
if [ "$KEEP_PLAN" = "1" ]; then
  terraform show -json drift.tfplan > drift.plan.json 2>/dev/null
  echo "[KEPT]  $(pwd)/drift.tfplan"
  echo "[KEPT]  $(pwd)/drift.plan.json"
else
  rm -f drift.tfplan
fi
exit $rc
