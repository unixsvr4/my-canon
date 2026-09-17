#!/usr/bin/env bash
# OS-layer drift detection with a record that outlives the fix - Lab 1's
# drift-check.sh, for the part of the machine Terraform can't see.
#
# "Drift" = any difference between a host and what the baseline role
# (site.yml) would converge it to, found by running the role in check mode.
#
#   ./drift-check.sh                   # whole fleet
#   ./drift-check.sh --limit db        # any ansible-playbook args pass through
#   ARCHIVE=0 ./drift-check.sh         # check only, write nothing
#
#   exit 0 = no drift    exit 2 = DRIFT    exit 1 = incomplete (a host failed or
#   was unreachable, or the run itself broke)
#
# WHY THIS WRAPPER EXISTS: `ansible-playbook --check` exits 0 even when it finds
# drift, so a scheduler alerting on exit codes stays green forever. This reads
# the per-host changed counts and turns them into an exit code.
#
# Incomplete beats drift on purpose: a host that could not be checked is not a
# host with no drift, and "partially checked, looked fine" is the report that
# hides the one box someone broke.
#
# Each finding is written to drift-history/<UTC stamp>/:
#   drift.txt   per-host, per-task unified diffs - for a human or a ticket
#   drift.json  the full ansible.posix.json result - for anything automated
# plus a row in drift-history/index.csv. Records are made read-only on write,
# and applying the baseline afterwards does not touch them.
#
# Diffs contain file contents. Anything secret must be templated by a task with
# `no_log: true`, which the callback censors - otherwise it lands in the record.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

ARCHIVE="${ARCHIVE:-1}"
SCOPE="${*:-all}"
RUN=.drift-run.json
ERR=.drift-run.err
HISTORY=drift-history
INDEX="$HISTORY/index.csv"
cleanup() { rm -f "$RUN" "$ERR"; }
trap cleanup EXIT

# Two things print into the same stdout as the JSON and corrupt it:
#   - profile_tasks (enabled in ansible.cfg). Setting ANSIBLE_CALLBACKS_ENABLED
#     to empty crashes ansible-core 2.21, so point it at the JSON callback.
#   - the retry-file hint ("to retry, use: --limit @..."), printed exactly when
#     a host fails or is unreachable - i.e. the run you most need recorded.
#     A read-only check has nothing to retry anyway.
ANSIBLE_CALLBACKS_ENABLED=ansible.posix.json \
ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
ANSIBLE_RETRY_FILES_ENABLED=false \
  ansible-playbook site.yml --check --diff "$@" > "$RUN" 2> "$ERR"
ansible_rc=$?

counts="$(python3 - "$RUN" <<'PY' 2>/dev/null
import json, sys
stats = json.load(open(sys.argv[1])).get("stats", {})
drifted = sum(1 for s in stats.values() if s.get("changed"))
not_checked = sum(1 for s in stats.values() if s.get("unreachable") or s.get("failures"))
print(len(stats), drifted, not_checked)
PY
)"
if [ -z "$counts" ]; then
  echo "[ERROR] drift run produced no usable result (ansible-playbook exit $ansible_rc)"
  cat "$ERR"; head -20 "$RUN"
  exit 1
fi
read -r total drifted not_checked <<< "$counts"

if [ "$total" -eq 0 ]; then
  echo "[ERROR] no hosts matched ($SCOPE) - checking nothing is not a clean result"
  exit 1
elif [ "$not_checked" -gt 0 ]; then
  rc=1; echo "[INCOMPLETE] $not_checked of $total host(s) could not be checked ($SCOPE)"
elif [ "$drifted" -gt 0 ]; then
  rc=2; echo "[DRIFT] $drifted of $total host(s) differ from baseline ($SCOPE)"
else
  rc=0; echo "[OK]    $total host(s) match baseline ($SCOPE)"
fi

if [ "$rc" -ne 0 ]; then
  echo "----- diff -----"
  ./drift-show.py --render "$RUN"
fi

if [ "$ARCHIVE" = "1" ] && [ "$rc" -ne 0 ]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$HISTORY/$stamp"
  n=2
  # Two runs in the same second must not collide: the first record is
  # read-only, so overwriting it would fail and silently lose the second.
  while [ -e "$dest" ]; do dest="$HISTORY/$stamp-$n"; n=$((n + 1)); done
  mkdir -p "$dest"

  cp "$RUN" "$dest/drift.json"
  ./drift-show.py --render "$RUN" > "$dest/drift.txt"
  chmod -w "$dest"/*

  [ -f "$INDEX" ] || echo "detected_utc,scope,exit_code,drifted_hosts,changed_tasks,not_checked,hosts,record" > "$INDEX"
  ./drift-show.py --index-row "$RUN" "$(basename "$dest")" "$SCOPE" "$rc" "$dest" >> "$INDEX"

  echo "[ARCHIVED] $dest/  (drift.txt, drift.json)"
  echo "[ARCHIVED] index: $INDEX"
fi
exit $rc
