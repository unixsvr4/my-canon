#!/usr/bin/env bash
# =============================================================================
# Simulate the 2am hand-edit on one host - and PROVE it landed.
#
#   ./tamper.sh          # db01
#   ./tamper.sh web02
#
# Edits two files the baseline role owns: the login banner, and the sshd
# hardening drop-in (re-enabling root login).
#
# Two ways a drift demo silently tests nothing, both guarded here:
#   1. No baseline yet. Fresh containers have no drop-in until site.yml has
#      converged once - there is nothing to drift FROM.
#   2. A `sed -i` that matches nothing exits 0 and changes nothing; the drift
#      check then reports clean and appears to work. So verify after editing.
# =============================================================================
set -euo pipefail
HOST="${1:-db01}"
C="lab-$HOST"
DROPIN=/etc/ssh/sshd_config.d/10-baseline.conf

if ! docker exec "$C" test -f "$DROPIN"; then
  echo "[NO BASELINE] $HOST has no $DROPIN - nothing to drift FROM."
  echo "              Converge first:  ansible-playbook site.yml"
  exit 1
fi

docker exec "$C" bash -c "
  echo 'hand-edited by someone at 2am' > /etc/motd
  sed -i 's/^PermitRootLogin no\$/PermitRootLogin yes/' $DROPIN
"

if docker exec "$C" grep -qx 'PermitRootLogin yes' "$DROPIN" \
   && docker exec "$C" grep -q '2am' /etc/motd; then
  echo "[TAMPERED] $HOST: /etc/motd rewritten; $DROPIN now says PermitRootLogin yes"
else
  echo "[TAMPER DID NOT LAND] $HOST - the edit matched nothing; a drift check now would prove nothing."
  docker exec "$C" grep -n PermitRootLogin "$DROPIN" || true
  exit 1
fi
