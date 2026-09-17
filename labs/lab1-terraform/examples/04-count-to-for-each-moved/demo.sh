#!/usr/bin/env bash
# Migrate count -> for_each on live state: first without moved blocks (what goes
# wrong), then with them (zero destroys).
cd "$(dirname "$0")"
source ../_lib.sh

WORK="$(pwd)/.work"   # absolute: the trap runs after we cd into it
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
cleanup
mkdir -p "$WORK"
cd "$WORK"

say "1. Deploy v1 (count) - this is the existing production state"
cp ../v1/main.tf .
tf init -input=false >/dev/null
tf apply -auto-approve >/dev/null
terraform state list | sed 's/^/   /'
IDS_BEFORE="$(terraform state show -no-color 'terraform_data.user[0]' | grep -E '^\s+id ' )"

say "2. Refactor to v2 (for_each) WITHOUT moved blocks, and plan"
cp ../v2/main.tf main.tf
tf plan -out=no-moved.tfplan >/dev/null
plan_summary no-moved.tfplan
note "-> every user destroyed and recreated. A pure refactor, planned as an outage."

say "3. Same refactor WITH moved.tf, and plan"
cp ../v2/moved.tf moved.tf
tf plan -out=moved.tfplan >/dev/null
plan_summary moved.tfplan
note "-> three moves, zero creates, zero destroys."

say "4. Apply it and confirm the objects survived"
tf apply -auto-approve moved.tfplan >/dev/null
terraform state list | sed 's/^/   /'
IDS_AFTER="$(terraform state show -no-color 'terraform_data.user["alice"]' | grep -E '^\s+id ')"
note "alice id before: $(echo "$IDS_BEFORE" | awk '{print $3}')"
note "alice id after:  $(echo "$IDS_AFTER" | awk '{print $3}')"
if [ "$IDS_BEFORE" = "$IDS_AFTER" ]; then
  note "-> same object, new address. Nothing was recreated."
else
  note "-> ids differ: the object was recreated (this should not happen)"; exit 1
fi
