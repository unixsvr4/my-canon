#!/usr/bin/env bash
# Walks through every for_each input shape and the unknown-keys error.
cd "$(dirname "$0")"
source ../_lib.sh
trap clean_tf EXIT
clean_tf
tf init -input=false >/dev/null

say "G first: keys unknown until apply (state is still empty, so seed.id is unknown)"
if tf plan -var demo_unknown_keys=true >plan-error.log 2>&1; then
  note "unexpected: plan succeeded"; exit 1
fi
for msg in "Error: Invalid for_each argument" "cannot be determined until apply"; do
  grep -o "$msg" plan-error.log | head -1 | sed 's/^/   /'
done
rm -f plan-error.log
note "-> key on a name you already know; put computed values in each.value."

say "Apply everything else"
tf apply -auto-approve >/dev/null
note "resource addresses - the KEY is the identity:"
terraform state list | sed 's/^/     /'

say "Outputs"
tf output | sed 's/^/   /'

say "Change one team's budget: only that key is touched"
tf plan -var 'teams={payments={owner="alice",budget=9000},risk={owner="bob",budget=3000}}' -out=budget.tfplan >/dev/null
plan_summary budget.tfplan
