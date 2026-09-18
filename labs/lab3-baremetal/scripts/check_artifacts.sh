#!/usr/bin/env bash
# =============================================================================
# Validate rendered artifacts with the REAL tools, in a throwaway container:
#   dhcpd -t        ISC DHCP's own config parser (snippet + generated reservations)
#   ksvalidator     pykickstart, the parser the RHEL installer uses
#   cloud-init schema  cloud-init's own schema validator, for the EC2 user data
#
# Unit tests prove the renderer does what we intended; these prove what we
# intended is valid. Both checks found real bugs the unit tests could not:
# an undeclared DHCP option (93), and a kickstart `network` line wrapped with
# backslashes, which kickstart does not support.
#
# The cloud-init check matters for the same reason as the other two, and it
# catches something a YAML test cannot: user data can be perfectly valid YAML
# and still be rejected or silently ignored by cloud-init, because the keys and
# their types are a schema. An unknown key, a string where a list belongs, or a
# missing "#cloud-config" first line produces an instance that boots, passes
# its health check, and ran none of its configuration.
#
# Requires Docker. ~40s, mostly package installs.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/render.py >/dev/null

docker run --rm \
  -v "$PWD/ipxe:/cfg:ro" \
  -v "$PWD/out:/etc/dhcp/generated:ro" \
  almalinux:9 bash -c '
    set -e
    dnf -q -y install dhcp-server pykickstart cloud-init >/dev/null 2>&1

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

    for ud in /etc/dhcp/generated/cloud-init/*.yaml; do
      if cloud-init schema --config-file "$ud" >/tmp/ci.log 2>&1; then
        echo "PASS  cloud-init schema: $(basename "$ud")"
      else
        echo "FAIL  cloud-init schema: $(basename "$ud")"; cat /tmp/ci.log; exit 1
      fi
    done
  '
