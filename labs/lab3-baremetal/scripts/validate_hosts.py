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


def load_hosts(path=HERE / "hosts.yml", key="hosts"):
    """PyYAML when available; a tiny stdlib reader otherwise, so this runs anywhere.

    `key` is the top-level mapping key to read, so the same reader handles
    hosts.yml (key "hosts") and cloud-hosts.yml (key "cloud_hosts") without a
    second implementation to keep in step.
    """
    text = Path(path).read_text()
    try:
        import yaml
        return yaml.safe_load(text)[key]
    except ImportError:
        pass
    hosts, cur = [], None
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.strip().startswith("#") or line.strip() == f"{key}:":
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


# =============================================================================
# The cloud half of the fleet (cloud-hosts.yml).
#
# Different fields, the same principle: refuse a record that would produce a
# broken machine, and report every problem at once. The rules are the ones a
# reviewer would actually apply, and three of them are about the FLEET rather
# than the record - a hostname that collides with a physical server, a service
# with every instance in one availability zone, a database that is not
# memory-optimised. Those are the mistakes that pass record-by-record review.
# =============================================================================
CLOUD_REQUIRED = ["hostname", "role", "service", "environment", "instance_type",
                  "availability_zone", "volume_size", "kernel_profile"]
INSTANCE_TYPE_RE = re.compile(r"^[a-z][a-z0-9]*\.(nano|micro|small|medium|large|"
                              r"x?[0-9]*xlarge|metal(-[0-9]+xl)?)$")
AZ_RE = re.compile(r"^[a-z]{2}(-[a-z]+)+-[0-9][a-z]$")
ENVIRONMENTS = {"dev", "staging", "prod"}
KERNEL_PROFILES = {"general", "throughput", "database", "low-latency", "container-host"}


def load_cloud_hosts(path=HERE / "cloud-hosts.yml"):
    return load_hosts(path, key="cloud_hosts")


def validate_cloud(cloud_hosts, physical_hosts=()):
    """Return a list of human-readable errors. Empty list = valid."""
    errors = []
    physical_names = {h.get("hostname") for h in physical_hosts}
    seen = {}
    by_service = {}

    for idx, host in enumerate(cloud_hosts):
        name = host.get("hostname", f"<entry {idx + 1}>")

        missing = [f for f in CLOUD_REQUIRED if not host.get(f)]
        if missing:
            errors.append(f"{name}: missing required field(s) {', '.join(missing)}")
            continue

        if not HOSTNAME_RE.match(name):
            errors.append(f"{name}: not a usable hostname (lowercase, digits, hyphens)")

        # One namespace across the whole fleet. Two machines answering to one
        # name breaks the Ansible inventory, every per-host record, and DNS -
        # and it is easy to do, because the two records live in two files.
        if name in seen:
            errors.append(f"{name}: duplicate hostname (also entry {seen[name] + 1})")
        seen[name] = idx
        if name in physical_names:
            errors.append(f"{name}: hostname is already used by a physical host in hosts.yml")

        if not INSTANCE_TYPE_RE.match(str(host["instance_type"])):
            errors.append(f"{name}: instance_type {host['instance_type']} is not a valid EC2 type")

        if not AZ_RE.match(str(host["availability_zone"])):
            errors.append(f"{name}: availability_zone {host['availability_zone']} is not an AZ "
                          "(it needs the zone letter, e.g. us-east-1a, not the region)")

        if str(host["environment"]) not in ENVIRONMENTS:
            errors.append(f"{name}: environment {host['environment']} is not one of "
                          f"{', '.join(sorted(ENVIRONMENTS))}")

        # The kernel profile is a contract with lab 2's role: an unknown value
        # is rejected by that role's argument_specs at converge time, which is
        # later and further away than here.
        if str(host["kernel_profile"]) not in KERNEL_PROFILES:
            errors.append(f"{name}: kernel_profile {host['kernel_profile']} is not one of "
                          f"{', '.join(sorted(KERNEL_PROFILES))} (see lab 2 roles/kernel)")

        try:
            size = int(host["volume_size"])
        except (TypeError, ValueError):
            errors.append(f"{name}: volume_size {host['volume_size']} is not a number")
        else:
            # 8 GiB is the floor for any current AMI; below it the instance
            # launches and the root filesystem fills during the first patch run.
            if size < 8:
                errors.append(f"{name}: volume_size {size} is below the 8 GiB minimum for an AMI")
            if host["role"] == "database" and size < 100:
                errors.append(f"{name}: a database with a {size} GiB root volume will fill; "
                              "give it at least 100")

        # A database on an instance type with no memory advantage is a choice
        # someone should have to make deliberately, not by copying a record.
        if host["role"] == "database" and not str(host["instance_type"]).startswith(("r", "x", "z")):
            errors.append(f"{name}: a database on {host['instance_type']} is not memory-optimised "
                          "(r/x/z family) - override deliberately or fix the record")

        by_service.setdefault((host["service"], host["environment"]), []).append(host)

    # FLEET RULE: a prod service whose instances are all in one AZ has no
    # availability story, however many instances it has. This is the check that
    # catches a copy-pasted record - the kind where the second instance was
    # added for capacity and nobody changed the zone.
    for (service, environment), group in sorted(by_service.items()):
        if environment != "prod" or len(group) < 2:
            continue
        zones = {h["availability_zone"] for h in group}
        if len(zones) == 1:
            errors.append(f"service {service} in {environment}: all {len(group)} instances are in "
                          f"{zones.pop()} - spread them across availability zones")

    return errors


def main():
    """Validate BOTH record sets, and report every error from both at once."""
    hosts = load_hosts()
    errors = [("hosts.yml", e) for e in validate(hosts)]

    cloud_path = HERE / "cloud-hosts.yml"
    if cloud_path.exists():
        cloud = load_cloud_hosts(cloud_path)
        errors += [("cloud-hosts.yml", e) for e in validate_cloud(cloud, hosts)]
    else:
        cloud = []

    if errors:
        print(f"{len(errors)} error(s) in the source of truth")
        for source, err in errors:
            print(f"  - {source}: {err}")
        return 1

    print(f"hosts.yml: {len(hosts)} physical host(s) valid")
    print(f"cloud-hosts.yml: {len(cloud)} cloud host(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
