#!/usr/bin/env bash
# Build the patch report from the per-host records. Runs at the end of a clean
# run, and by hand after an aborted one.
set -euo pipefail
cd "$(dirname "$0")"
ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
out="reports/patch-report-${ts}.csv"
mkdir -p reports/run

{
  echo "host,groups,status,kernel_before,rebooted,packages,started_at"
  cat reports/run/*.csv 2>/dev/null | sort || true
} > "$out"

total=$(cat reports/run/*.csv 2>/dev/null | grep -c . || true)
ok=$(grep -ho 'SUCCESS' reports/run/*.csv 2>/dev/null | wc -l | tr -d ' ' || true)
bad=$(grep -ho 'FAILED_HEALTH_GATE' reports/run/*.csv 2>/dev/null | wc -l | tr -d ' ' || true)
echo "report: $out"
echo "attempted=${total}  patched=${ok}  quarantined=${bad}"
echo "NOT attempted (run aborted before reaching them) = every host in inventory without a row above"
