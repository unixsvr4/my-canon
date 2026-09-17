#!/usr/bin/env bash
# =============================================================================
# Idempotence test: converge, then run AGAIN and require zero changes.
#
#   tests/idempotence.sh                                   # site.yml, all hosts
#   tests/idempotence.sh site.yml --limit web01            # extra args pass through
#   tests/idempotence.sh examples/idempotence/not-idempotent.yml   # expected to FAIL
#
# Why this is the test that matters: a play that reports "changed" on a host
# that is already correct is either doing unnecessary work (restarts, rewrites)
# or cannot tell correct from incorrect. Either way its drift report is noise.
#
# This is what `molecule test` does in its idempotence step; it is reproduced
# here with plain ansible-playbook so it runs anywhere ansible does.
#
# exit 0 = idempotent   exit 1 = second run changed something (listed)
# exit 2 = the converge run itself failed
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PLAYBOOK="${1:-site.yml}"
[ $# -gt 0 ] && shift
OUT=reports/idempotence
mkdir -p "$OUT"
name="$(basename "$PLAYBOOK" .yml)"

# JSON output for the second run, so changed tasks are parsed, not grepped.
# profile_tasks is replaced (it prints into stdout and corrupts the JSON), and
# retry files are off (their hint is printed into stdout on failure).
json_run() {
  ANSIBLE_CALLBACKS_ENABLED=ansible.posix.json \
  ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
  ANSIBLE_RETRY_FILES_ENABLED=false \
    ansible-playbook "$PLAYBOOK" "$@"
}

echo "== run 1: converge ($PLAYBOOK $*)"
if ! json_run "$@" > "$OUT/$name-run1.json" 2> "$OUT/$name-run1.err"; then
  echo "   converge FAILED - see $OUT/$name-run1.json"
  python3 - "$OUT/$name-run1.json" <<'PY' || true
import json, sys
run = json.load(open(sys.argv[1]))
for play in run["plays"]:
    for t in play["tasks"]:
        for host, r in t["hosts"].items():
            if r.get("failed") or r.get("unreachable"):
                print(f"   {host}: {t['task']['name']}: {r.get('msg', '')}")
PY
  exit 2
fi
echo "   ok"

echo "== run 2: must change nothing"
json_run "$@" > "$OUT/$name-run2.json" 2> "$OUT/$name-run2.err"

python3 - "$OUT/$name-run2.json" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
changed = {}
for play in run["plays"]:
    for t in play["tasks"]:
        for host, r in t["hosts"].items():
            if r.get("changed"):
                changed.setdefault(host, []).append(t["task"]["name"])
hosts = sorted(run["stats"])
width = max(len(h) for h in hosts)
for h in hosts:
    n = run["stats"][h]["changed"]
    mark = "PASS" if n == 0 else "FAIL"
    print(f"   {mark}  {h:<{width}}  changed={n}")
    for task in changed.get(h, []):
        print(f"           - {task}")
if changed:
    print(f"\nNOT IDEMPOTENT: {len(changed)} of {len(hosts)} host(s) changed on a second run.")
    sys.exit(1)
print(f"\nIDEMPOTENT: {len(hosts)} host(s), zero changes on the second run.")
PY
