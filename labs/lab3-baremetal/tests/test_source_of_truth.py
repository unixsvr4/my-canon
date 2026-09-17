#!/usr/bin/env python3
"""Unit tests for the source-of-truth validator and the artifact renderer.

    python3 -m unittest discover -s tests -v        # from labs/lab3-baremetal

Standard library only. Each test copies a known-good host record and breaks
exactly one thing, so a failure points at one rule.
"""
import copy
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE / "scripts"))

from render import RenderError, mac_filename, netmask, render_dhcp, render_inventory, render_kickstart  # noqa: E402
from validate_hosts import load_hosts, validate  # noqa: E402

TEMPLATE = (HERE / "kickstart" / "rhel9-min.ks.j2").read_text()


class SourceOfTruthIsValid(unittest.TestCase):
    def test_committed_hosts_file_is_valid(self):
        self.assertEqual(validate(load_hosts()), [])

    def test_stdlib_reader_matches_pyyaml(self):
        """The fallback reader must produce the same records PyYAML does."""
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        text = (HERE / "hosts.yml").read_text()
        real = yaml.safe_load(text)["hosts"]
        sys.modules["yaml_backup"] = sys.modules.pop("yaml")
        try:
            import builtins
            real_import = builtins.__import__

            def no_yaml(name, *args, **kwargs):
                if name == "yaml":
                    raise ImportError
                return real_import(name, *args, **kwargs)

            builtins.__import__ = no_yaml
            fallback = load_hosts()
        finally:
            builtins.__import__ = real_import
            sys.modules["yaml"] = sys.modules.pop("yaml_backup")
        self.assertEqual(real, fallback)


class ValidatorRejectsBadRecords(unittest.TestCase):
    def setUp(self):
        self.good = load_hosts()[0]

    def broken(self, **changes):
        h = copy.deepcopy(self.good)
        h.update(changes)
        return h

    def assertRejected(self, hosts, fragment):
        errors = validate(hosts)
        self.assertTrue(any(fragment in e for e in errors), f"expected {fragment!r} in {errors}")

    def test_missing_field(self):
        h = copy.deepcopy(self.good)
        del h["vlan"]
        self.assertRejected([h], "missing vlan")

    def test_duplicate_mac(self):
        other = self.broken(hostname="canon-gw99", ip="10.20.4.99", unit=40)
        self.assertRejected([self.good, other], "duplicate mac")

    def test_duplicate_ip(self):
        other = self.broken(hostname="canon-gw99", mac="3c:ec:ef:99:99:99", unit=40)
        self.assertRejected([self.good, other], "duplicate ip")

    def test_two_servers_in_one_rack_unit(self):
        other = self.broken(hostname="canon-gw99", mac="3c:ec:ef:99:99:99", ip="10.20.4.99")
        self.assertRejected([self.good, other], "duplicate rack/unit")

    def test_gateway_outside_subnet(self):
        self.assertRejected([self.broken(gateway="10.99.0.1")], "is not in 10.20.4.0/24")

    def test_host_uses_broadcast_address(self):
        self.assertRejected([self.broken(ip="10.20.4.255")], "broadcast address")

    def test_vlan_out_of_range(self):
        self.assertRejected([self.broken(vlan=5000)], "outside 1-4094")

    def test_single_member_bond(self):
        self.assertRejected([self.broken(bond_members=["ens1f0"])], "at least two members")

    def test_uppercase_mac(self):
        self.assertRejected([self.broken(mac="3C:EC:EF:11:22:33")], "not a lowercase colon-separated MAC")

    def test_unknown_profile(self):
        self.assertRejected([self.broken(profile="windows-2022")], "unknown profile")


class RendererProducesCompleteArtifacts(unittest.TestCase):
    def setUp(self):
        self.hosts = load_hosts()

    def test_kickstart_has_no_unrendered_placeholders(self):
        for h in self.hosts:
            ks = render_kickstart(h, TEMPLATE)
            self.assertNotIn("{{", ks, h["hostname"])

    def test_kickstart_carries_identity_and_network(self):
        h = self.hosts[0]
        ks = render_kickstart(h, TEMPLATE)
        self.assertIn(f"--hostname={h['hostname']}", ks)
        self.assertIn(f"--vlanid={h['vlan']}", ks)
        self.assertIn("--bondslaves=ens1f0,ens1f1", ks)
        self.assertIn("--netmask=255.255.255.0", ks)

    def test_kickstart_has_no_line_continuations(self):
        """Kickstart has no backslash continuation; a wrapped command silently breaks.

        Regression: the network line was once wrapped with backslashes, which
        ksvalidator reports as unknown commands (scripts/check_artifacts.sh).
        """
        for n, line in enumerate(TEMPLATE.splitlines(), 1):
            self.assertFalse(line.rstrip().endswith("\\"), f"line {n} ends with a backslash")

    def test_missing_template_value_is_a_hard_error(self):
        h = copy.deepcopy(self.hosts[0])
        h["vlan"] = ""
        with self.assertRaisesRegex(RenderError, "template wants 'vlan'"):
            render_kickstart(h, TEMPLATE)

    def test_kickstart_filename_matches_ipxe_request_path(self):
        # boot.ipxe asks for ks/${mac:hexhyp}.cfg
        self.assertEqual(mac_filename("3c:ec:ef:11:22:33"), "3c-ec-ef-11-22-33")
        self.assertIn("${mac:hexhyp}.cfg", (HERE / "ipxe" / "boot.ipxe").read_text())

    def test_netmask_from_prefix(self):
        self.assertEqual(netmask(24), "255.255.255.0")
        self.assertEqual(netmask(22), "255.255.252.0")

    def test_dhcp_has_one_reservation_per_host(self):
        conf = render_dhcp(self.hosts)
        self.assertEqual(conf.count("hardware ethernet"), len(self.hosts))
        for h in self.hosts:
            self.assertIn(f"fixed-address {h['ip']};", conf)

    def test_inventory_hands_every_host_to_ansible(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        inv = yaml.safe_load(render_inventory(self.hosts))
        children = inv["all"]["children"]
        self.assertEqual(set(children["rhel9"]["hosts"]), {h["hostname"] for h in self.hosts})
        self.assertIn("canon-db01", children["database"]["hosts"])
        self.assertIn("rhel9", children["newly_built"]["children"])


if __name__ == "__main__":
    unittest.main()
