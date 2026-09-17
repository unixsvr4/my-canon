#!/usr/bin/env bash
# Nested for_each: stable data-derived keys vs positional keys.
cd "$(dirname "$0")"
source ../_lib.sh
trap clean_tf EXIT
clean_tf
tf init -input=false >/dev/null

say "1. Expand services x ports x CIDRs into rules"
tf apply -auto-approve >/dev/null
tf output rule_keys | sed 's/^/   /'

say "2. Add a CIDR to api - only the new rules should appear"
tf plan -out=add-cidr.tfplan \
  -var 'services={api={ports=[443,8443],cidrs=["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12"]},web={ports=[80,443],cidrs=["0.0.0.0/0"]}}' >/dev/null
plan_summary add-cidr.tfplan
note "rule[...]:        2 creates - exactly the two new (port, 172.16.0.0/12) rules."
note "rule_positional:  the new CIDR lands mid-list, so every later index shifts:"
note "                  4 existing rules REPLACED just to ADD two. Adding should never replace."

say "3. Remove port 80 from web - stable keys vs positional keys"
tf plan -out=remove-port.tfplan \
  -var 'services={api={ports=[443,8443],cidrs=["10.0.0.0/8","192.168.0.0/16"]},web={ports=[443],cidrs=["0.0.0.0/0"]}}' >/dev/null
plan_summary remove-port.tfplan

say "What just happened"
note "Step 3 - rule[...]: ONE destroy - web:80:0.0.0.0/0. Nothing else is touched."
note "rule_positional:  web:80 was the second-to-last rule in the flattened list, so the"
note "                  rule after it slides down an index -> a REPLACE plus a destroy."
note "                  Put the removed item near the front and every later rule churns."
note "                  On a live security group that is a window where traffic is dropped."
note ""
note "for_each is only as good as its key. Derive the key from the data's identity."
