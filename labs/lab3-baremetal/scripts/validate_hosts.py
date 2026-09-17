#!/usr/bin/env python3
"""Validate the source of truth before anything is rendered from it.

    ./scripts/validate_hosts.py            # exit 0 = valid, 1 = errors listed

A build pipeline that renders an incomplete or contradictory answer file is
worse than no pipeline: the mistake surfaces at 3 a.m., on a console, in a data
centre nobody can get into. So every rule a human reviewer would check is
checked here, and all errors are reported at once rather than one per run.
"""
import ipaddress
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE / "scripts"))

REQUIRED = ["hostname", "mac", "ip", "prefix", "gateway", "nameserver", "vlan",
            "role", "profile", "rack", "unit", "bond_members", "disk"]
MAC_RE = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")
HOSTNAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,62}$")
PROFILES = {"rhel9-min"}


def load_hosts(path=HERE / "hosts.yml"):
    """PyYAML when available; a tiny stdlib reader otherwise, so this runs anywhere."""
    text = Path(path).read_text()
    try:
        import yaml
        return yaml.safe_load(text)["hosts"]
    except ImportError:
        pass
    hosts, cur = [], None
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.strip().startswith("#") or line.strip() == "hosts:":
            continue
        if line.lstrip().startswith("- "):
            cur = {}
            hosts.append(cur)
            line = line.replace("- ", "  ", 1)
        key, _, value = line.strip().partition(":")
        value = value.strip().strip('"')
        if value.startswith("["):
            value = [v.strip() for v in value.strip("[]").split(",") if v.strip()]
        elif value.isdigit():
            value = int(value)
        cur[key] = value
    return hosts


def validate(hosts):
    """Return a list of human-readable errors. Empty list = valid."""
    errors = []
    seen = {"hostname": {}, "mac": {}, "ip": {}, "rack/unit": {}}

    for i, h in enumerate(hosts):
        name = h.get("hostname", f"<entry {i}>")

        missing = [k for k in REQUIRED if h.get(k) in (None, "", [])]
        if missing:
            errors.append(f"{name}: missing {', '.join(missing)}")
            continue

        if not HOSTNAME_RE.match(str(h["hostname"])):
            errors.append(f"{name}: hostname must be lowercase letters, digits, hyphens")
        if not MAC_RE.match(str(h["mac"])):
            errors.append(f"{name}: mac {h['mac']!r} is not a lowercase colon-separated MAC")
        if h["profile"] not in PROFILES:
            errors.append(f"{name}: unknown profile {h['profile']!r} (known: {', '.join(sorted(PROFILES))})")

        try:
            vlan = int(h["vlan"])
            if not 1 <= vlan <= 4094:
                errors.append(f"{name}: vlan {vlan} outside 1-4094")
        except (TypeError, ValueError):
            errors.append(f"{name}: vlan {h['vlan']!r} is not a number")

        if not isinstance(h["bond_members"], list) or len(h["bond_members"]) < 2:
            errors.append(f"{name}: a bond needs at least two members, got {h['bond_members']!r}")

        if not str(h["disk"]).startswith("/dev/"):
            errors.append(f"{name}: disk {h['disk']!r} is not a /dev path")

        try:
            iface = ipaddress.ip_interface(f"{h['ip']}/{h['prefix']}")
            gateway = ipaddress.ip_address(str(h["gateway"]))
            if gateway not in iface.network:
                errors.append(f"{name}: gateway {gateway} is not in {iface.network} - the host could never reach it")
            if iface.ip in (iface.network.network_address, iface.network.broadcast_address):
                errors.append(f"{name}: {iface.ip} is the network or broadcast address of {iface.network}")
            if iface.ip == gateway:
                errors.append(f"{name}: host ip is the gateway address")
        except ValueError as exc:
            errors.append(f"{name}: bad addressing: {exc}")

        # Uniqueness: two records claiming one identity is always a data error.
        for field, value in (("hostname", h["hostname"]), ("mac", h["mac"]), ("ip", h["ip"]),
                             ("rack/unit", f"{h['rack']}/U{h['unit']}")):
            other = seen[field].get(str(value))
            if other:
                errors.append(f"{name}: duplicate {field} {value} (also used by {other})")
            else:
                seen[field][str(value)] = name

    return errors


def main():
    hosts = load_hosts()
    errors = validate(hosts)
    if errors:
        print(f"hosts.yml: {len(errors)} error(s)")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"hosts.yml: {len(hosts)} host(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
