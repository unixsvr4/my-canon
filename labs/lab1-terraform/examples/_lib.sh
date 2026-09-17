#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helpers for the example demo scripts. Sourced, not run.
#
# plan_summary <planfile> prints one line per resource the plan touches, using
# the machine-readable plan (terraform show -json) rather than scraping text:
#
#   destroy  terraform_data.by_name["alice"]
#   REPLACE  terraform_data.by_index[0]
#   move     terraform_data.user["alice"]   (from terraform_data.user[0])
#   ---
#   0 create, 0 update, 2 replace, 3 destroy, 0 move
#
# Requires jq.
# -----------------------------------------------------------------------------
set -euo pipefail

command -v terraform >/dev/null || { echo "terraform not found on PATH"; exit 1; }
command -v jq >/dev/null || { echo "jq not found on PATH (brew install jq)"; exit 1; }

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

tf() { terraform "$@" -no-color; }

plan_summary() {
  terraform show -json "$1" | jq -r '
    def kind:
      if   .change.actions == ["create"]                                      then "create "
      elif .change.actions == ["update"]                                      then "update "
      elif .change.actions == ["delete"]                                      then "destroy"
      elif (.change.actions | sort) == ["create", "delete"]                   then "REPLACE"
      elif .change.actions == ["no-op"] and .previous_address != null         then "move   "
      else (.change.actions | join("+")) end;

    [ .resource_changes[]
      | select(.change.actions != ["no-op"] or .previous_address != null) ] as $c
    | ( $c[] | "   \(kind)  \(.address)\(if .previous_address then "   (from \(.previous_address))" else "" end)" ),
      "   ---",
      "   \([$c[] | select(.change.actions == ["create"])] | length) create, \([$c[] | select(.change.actions == ["update"])] | length) update, \([$c[] | select((.change.actions | length) == 2)] | length) replace, \([$c[] | select(.change.actions == ["delete"])] | length) destroy, \([$c[] | select(.change.actions == ["no-op"])] | length) move"
  '
}

# Remove everything a demo creates, so each run starts clean and nothing is
# left behind to be committed by accident.
clean_tf() {
  rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup terraform.tfstate.d ./*.tfplan
}
