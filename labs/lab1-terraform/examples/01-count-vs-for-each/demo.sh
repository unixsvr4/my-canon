#!/usr/bin/env bash
# Reproduces the classic count re-indexing failure next to the for_each fix.
cd "$(dirname "$0")"
source ../_lib.sh
trap clean_tf EXIT
clean_tf

say "1. Create three users, both ways"
tf init -input=false >/dev/null
tf apply -auto-approve >/dev/null
terraform state list | sed 's/^/   /'

say "2. Remove \"alice\" - the FIRST element - and plan"
tf plan -var 'users=["bob","carol"]' -out=remove-alice.tfplan >/dev/null
plan_summary remove-alice.tfplan

say "What just happened"
note "count:    [0] alice->bob and [1] bob->carol are REPLACED, [2] is destroyed."
note "          Two users nobody asked to change are torn down and rebuilt."
note "for_each: exactly one destroy - [\"alice\"]. bob and carol are not touched."
note ""
note "On a real resource that REPLACE is a deleted IAM user (keys revoked), a"
note "recreated VM, or a dropped bucket. Use count only for identical, fungible"
note "copies (count = var.enabled ? 1 : 0 is the one common legitimate use)."
