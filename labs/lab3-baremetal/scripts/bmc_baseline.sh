#!/usr/bin/env bash
# Out-of-band baseline via Redfish - the vendor-neutral BMC API. This is what
# replaces "somebody clicks through the iLO GUI and hopefully remembers the
# same settings next time".
#
# REFERENCE ONLY: it points at a BMC that does not exist here. Read it, don't run it.
set -euo pipefail

BMC="${1:?usage: bmc_baseline.sh <bmc-address>}"
CRED="${BMC_CRED:?export BMC_CRED=user:pass  (from Vault, never hardcoded)}"
API="https://${BMC}/redfish/v1"

# 1. What is this machine? (model, serial, power state, health)
curl -sku "$CRED" "$API/Systems/1" | python3 -m json.tool | head -30

# 2. Firmware inventory - drift between "identical" servers usually lives here
curl -sku "$CRED" "$API/UpdateService/FirmwareInventory"

# 3. BIOS settings as CODE. Latency-sensitive build standard:
curl -sku "$CRED" -X PATCH "$API/Systems/1/Bios/Settings" \
  -H 'Content-Type: application/json' \
  -d '{"Attributes":{
        "PowerProfile":"MaxPerformance",
        "ProcC6Report":"Disabled",
        "IntelHyperThreading":"Enabled",
        "BootMode":"Uefi",
        "PxeDev1EnDis":"Enabled"
      }}'

# 4. One-time PXE boot, then power on - this is "rebuild" as an API call
curl -sku "$CRED" -X PATCH "$API/Systems/1" \
  -H 'Content-Type: application/json' \
  -d '{"Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"Pxe"}}'
curl -sku "$CRED" -X POST "$API/Systems/1/Actions/ComputerSystem.Reset" \
  -H 'Content-Type: application/json' -d '{"ResetType":"ForceRestart"}'

# 5. Serial-over-LAN is the console when the OS is gone. Knowing this exists is
#    the difference between debugging a failed build remotely and driving to the data centre.
echo "SOL: ipmitool -I lanplus -H ${BMC} -U <user> -P <pass> sol activate"
