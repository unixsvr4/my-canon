#!/usr/bin/env bash
# =============================================================================
# Validate rendered artifacts with the REAL tools, in a throwaway container:
#   dhcpd -t        ISC DHCP's own config parser (snippet + generated reservations)
#   ksvalidator     pykickstart, the parser the RHEL installer uses
#
# Unit tests prove the renderer does what we intended; these prove what we
# intended is valid. Both checks found real bugs the unit tests could not:
# an undeclared DHCP option (93), and a kickstart `network` line wrapped with
# backslashes, which kickstart does not support.
#
# Requires Docker. ~30s, mostly package installs.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/render.py >/dev/null

docker run --rm \
  -v "$PWD/ipxe:/cfg:ro" \
  -v "$PWD/out:/etc/dhcp/generated:ro" \
  almalinux:9 bash -c '
    set -e
    dnf -q -y install dhcp-server pykickstart >/dev/null 2>&1

    if /usr/sbin/dhcpd -t -4 -cf /cfg/dhcpd.conf.snippet >/tmp/dhcpd.log 2>&1; then
      echo "PASS  dhcpd -t: snippet + generated reservations"
    else
      echo "FAIL  dhcpd -t"; grep -vE "^(Internet Systems|Copyright|All rights|For info)" /tmp/dhcpd.log; exit 1
    fi

    for ks in /etc/dhcp/generated/ks/*.cfg; do
      if ksvalidator -v RHEL9 "$ks" >/tmp/ks.log 2>&1; then
        echo "PASS  ksvalidator RHEL9: $(basename "$ks")"
      else
        echo "FAIL  ksvalidator RHEL9: $(basename "$ks")"; cat /tmp/ks.log; exit 1
      fi
    done
  '
