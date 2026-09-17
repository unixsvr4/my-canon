# ipxe/ — network boot

| File | Role |
|---|---|
| `dhcpd.conf.snippet` | ISC DHCP: subnets, the boot-file decision, and a global include of the **generated** reservations |
| `boot.ipxe` | the iPXE script: MAC as identity, fetch over HTTP, refuse unregistered machines |

## Boot sequence

```text
NIC PXE ROM ── DHCP DISCOVER ──► dhcpd: known MAC? reservation + boot file by architecture
            ◄── undionly.kpxe (BIOS) or ipxe.efi (UEFI, option 93 = 0x0007)
iPXE        ── DHCP again, user-class "iPXE" ──► dhcpd: now hand out the SCRIPT, not the binary
            ◄── http://.../boot.ipxe
boot.ipxe   ── GET /ipxe/host?mac=<mac> ──► provisioning service: this MAC's profile, or "unregistered"
            ── kernel + initrd over HTTP, inst.ks=http://.../ks/<mac>.cfg ──► installer
```

## Details in `dhcpd.conf.snippet`

- **`if exists user-class and option user-class = "iPXE"`** breaks the chainload loop. Without it, iPXE's own DHCP request gets the iPXE binary again, forever.
- **`option client-arch code 93 = unsigned integer 16;`** has to be *declared*. ISC dhcpd doesn't predefine it, and `dhcpd -t` rejects a config that tests an undeclared option (a bug the first version of this file had).
- **Reservations are included at global scope** from `out/dhcpd-hosts.conf`. Host declarations are global in ISC dhcpd, and the generated file spans both subnets.
- **The helper address** (`ip helper-address` on each VLAN's gateway) is outside this file and is the most common reason a DISCOVER never arrives.

## Details in `boot.ipxe`

- **HTTP, not TFTP** for the kernel and initrd. TFTP has no windowing and stalls on busy or high-latency links.
- **`${mac:hexhyp}`** gives `3c-ec-ef-11-22-33`, the exact filename `scripts/render.py` writes.
- **Unregistered MAC → no build.** The provisioning service answers "unknown", and the script prints a message and offers a shell instead of installing anything.
- **Serial console** (`console=ttyS0,115200n8`) on the kernel line, so installs are visible over serial-over-LAN.

Validate with the real parser: `../scripts/check_artifacts.sh`.
