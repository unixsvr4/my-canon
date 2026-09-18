#!/usr/bin/env python3
"""Unit tests for the source-of-truth validator and the artifact renderer.

    python3 -m unittest discover -s tests -v        # from labs/lab3-baremetal

Standard library only. Each test copies a known-good host record and breaks
exactly one thing, so a failure points at one rule.
"""
import copy
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE / "scripts"))

from render import (RenderError, cloud_tags, mac_filename, netmask,  # noqa: E402
                    render_cloud_init, render_dhcp, render_inventory,
                    render_inventory_preview, render_kickstart, render_tfvars)
from validate_hosts import (load_cloud_hosts, load_hosts,  # noqa: E402
                            validate, validate_cloud)

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


# =============================================================================
# The cloud half of the fleet (cloud-hosts.yml -> EC2).
# =============================================================================
class CloudSourceOfTruthIsValid(unittest.TestCase):
    def setUp(self):
        self.cloud = load_cloud_hosts()
        self.physical = load_hosts()

    def test_committed_cloud_file_is_valid(self):
        self.assertEqual(validate_cloud(self.cloud, self.physical), [])


class CloudValidatorRejectsBadRecords(unittest.TestCase):
    """Every rule, watched failing. A validator nobody has seen reject anything
    is a validator that might be checking nothing - see RESEARCH.md T8 and A16
    for two cases where exactly that happened."""

    def setUp(self):
        self.cloud = load_cloud_hosts()
        self.physical = load_hosts()

    def broken(self, index=0, **changes):
        records = copy.deepcopy(self.cloud)
        records[index].update(changes)
        return validate_cloud(records, self.physical)

    def assert_rejected(self, errors, fragment):
        self.assertTrue(any(fragment in e for e in errors),
                        f"expected an error containing {fragment!r}, got {errors}")

    def test_missing_field(self):
        records = copy.deepcopy(self.cloud)
        del records[0]["instance_type"]
        self.assert_rejected(validate_cloud(records, self.physical), "missing required field")

    def test_region_instead_of_availability_zone(self):
        # The mistake that launches everything in one zone: "us-east-1" is a
        # region, and an API call with it as the AZ fails at apply time.
        self.assert_rejected(self.broken(availability_zone="us-east-1"), "is not an AZ")

    def test_invalid_instance_type(self):
        self.assert_rejected(self.broken(instance_type="m7g.humongous"),
                             "is not a valid EC2 type")

    def test_hostname_collides_with_a_physical_host(self):
        self.assert_rejected(self.broken(hostname=self.physical[0]["hostname"]),
                             "already used by a physical host")

    def test_duplicate_cloud_hostname(self):
        records = copy.deepcopy(self.cloud)
        records[1]["hostname"] = records[0]["hostname"]
        self.assert_rejected(validate_cloud(records, self.physical), "duplicate hostname")

    def test_unknown_kernel_profile(self):
        # The contract with lab 2's kernel role: caught here rather than by
        # that role's argument_specs at converge time.
        self.assert_rejected(self.broken(kernel_profile="fast"), "kernel_profile")

    def test_unknown_environment(self):
        self.assert_rejected(self.broken(environment="production"), "environment")

    def test_root_volume_below_the_ami_minimum(self):
        self.assert_rejected(self.broken(volume_size=4), "below the 8 GiB minimum")

    def test_database_with_a_small_root_volume(self):
        db = next(i for i, h in enumerate(self.cloud) if h["role"] == "database")
        self.assert_rejected(self.broken(index=db, volume_size=20), "will fill")

    def test_database_on_a_general_purpose_instance(self):
        db = next(i for i, h in enumerate(self.cloud) if h["role"] == "database")
        self.assert_rejected(self.broken(index=db, instance_type="m7g.xlarge"),
                             "not memory-optimised")

    def test_prod_service_entirely_in_one_availability_zone(self):
        # The fleet rule: a copy-pasted record where the zone was not changed.
        # Every instance is individually valid, and the service has no
        # availability story.
        records = copy.deepcopy(self.cloud)
        zone = records[0]["availability_zone"]
        for r in records:
            r["availability_zone"] = zone
        self.assert_rejected(validate_cloud(records, self.physical),
                             "spread them across availability zones")


class CloudRendererProducesUsableArtifacts(unittest.TestCase):
    def setUp(self):
        self.cloud = load_cloud_hosts()
        self.host = self.cloud[0]

    def test_user_data_starts_with_the_cloud_config_marker(self):
        # cloud-init reads the FIRST line to decide the format. Without
        # "#cloud-config" the file is treated as a shell script, and the whole
        # thing is silently ignored - the instance boots, and nothing in it ran.
        self.assertTrue(render_cloud_init(self.host).startswith("#cloud-config\n"))

    def test_user_data_is_valid_yaml_and_sets_identity(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        doc = yaml.safe_load(render_cloud_init(self.host))
        self.assertEqual(doc["hostname"], self.host["hostname"])
        self.assertFalse(doc["preserve_hostname"])

    def test_user_data_never_upgrades_packages_on_first_boot(self):
        # Two instances launched an hour apart must be the same machine.
        # Patching is patch.yml's job, with a health gate.
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        doc = yaml.safe_load(render_cloud_init(self.host))
        self.assertFalse(doc["package_upgrade"])
        self.assertFalse(doc["package_update"])

    def test_every_cloud_host_gets_the_mandatory_tags(self):
        # The same mandatory keys lab 1's Terraform module enforces with a
        # `terraform test` assertion.
        for host in self.cloud:
            tags = cloud_tags(host)
            for key in ("Name", "Environment", "Role", "Service", "ManagedBy"):
                self.assertIn(key, tags, host["hostname"])

    def test_tfvars_is_a_map_keyed_by_hostname(self):
        # A map, not a list: removing one instance must destroy that one
        # instance. See examples/01-count-vs-for-each for the list version of
        # this, reproduced.
        data = json.loads(render_tfvars(self.cloud))
        self.assertEqual(set(data["instances"]), {h["hostname"] for h in self.cloud})

    def test_tfvars_volume_size_is_a_number_not_a_string(self):
        # Terraform's type system would reject a string here, at plan time, on
        # a file a human never reads.
        data = json.loads(render_tfvars(self.cloud))
        for name, spec in data["instances"].items():
            self.assertIsInstance(spec["volume_size"], int, name)

    def test_tag_contract_produces_the_groups_the_playbooks_target(self):
        """THE CONTRACT TEST between all three labs.

        Lab 1 stamps the tags, lab 2's aws_ec2 inventory turns them into
        groups, and the playbooks target those groups by name. If a tag value
        changes, `--limit tag_Role_database` matches nothing and the play
        reports "no hosts matched" and exits 0 - a rollout that touched zero
        hosts, looking exactly like success.
        """
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        preview = yaml.safe_load(render_inventory_preview(self.cloud))
        groups = preview["all"]["children"]

        for expected in ("tag_Environment_prod", "tag_Role_database", "tag_Service_api"):
            self.assertIn(expected, groups)

        # The database host is in the database group, and only it.
        db = [h["hostname"] for h in self.cloud if h["role"] == "database"]
        self.assertEqual(sorted(groups["tag_Role_database"]["hosts"]), sorted(db))

        # Availability-zone groups exist and are distinct, so a rollout can
        # batch by zone rather than hoping `serial` does not take out an AZ.
        az_groups = [g for g in groups if g.startswith("az_")]
        self.assertGreaterEqual(len(az_groups), 2)


if __name__ == "__main__":
    unittest.main()
