"""Run without root: python3 -m unittest discover -s tests -v."""

import importlib.util
import ipaddress
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
  "host_config", Path(__file__).resolve().parents[1] / "scripts/host_config.py"
)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)

UUID = "00000000-0000-0000-0000-000000000001"
FIREWALL = """# OCI image firewall
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:InstanceServices - [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
-A OUTPUT -d 169.254.0.0/16 -j InstanceServices
-A InstanceServices -d 169.254.0.2/32 -p tcp --dport 3260 -j ACCEPT
-A InstanceServices -d 169.254.0.0/16 -p tcp -j REJECT --reject-with tcp-reset
COMMIT
"""


class HostConfigTests(unittest.TestCase):
  def test_incus_bridge_has_a_usable_address_outside_vcn_and_docker_pools(self):
    bridge = ipaddress.IPv4Interface(host.INCUS_IPV4_ADDRESS)
    self.assertNotIn(bridge.ip, (bridge.network.network_address, bridge.network.broadcast_address))
    for network in ("10.0.0.0/16", "172.16.0.0/12", "192.168.0.0/16"):
      self.assertFalse(bridge.network.overlaps(ipaddress.IPv4Network(network)))

  def test_fstab_preserves_system_entries_and_is_idempotent(self):
    original = "LABEL=cloudimg-rootfs / ext4 defaults 0 1\n"
    result = host.fstab_config(original, UUID, include_runtimes=True)
    self.assertTrue(result.startswith(original))
    self.assertIn(f"UUID={UUID} /data ext4 defaults,_netdev,nofail 0 2", result)
    self.assertEqual(host.fstab_config(result, UUID, include_runtimes=True), result)
    for app in host.APPS:
      self.assertIn(
        f"/data/var/lib/{app} /var/lib/{app} none bind,_netdev,nofail,x-systemd.requires=/data",
        result,
      )

  def test_fstab_adopts_matching_existing_entries_without_duplicates(self):
    original = (
      f"UUID={UUID} /data ext4 defaults,_netdev,nofail 0 2\n"
      "/data/var/lib/incus /var/lib/incus none bind,_netdev,x-systemd.requires=/data 0 0\n"
    )
    result = host.fstab_config(original, UUID, include_runtimes=True)
    self.assertEqual(result.count(f"UUID={UUID}"), 1)
    self.assertEqual(result.count("/data/var/lib/incus /var/lib/incus"), 1)

  def test_required_storage_keeps_existing_runtime_mount_entries(self):
    existing = host.fstab_config("LABEL=root / ext4 defaults 0 1\n", UUID, include_runtimes=True)
    result = host.fstab_config(existing, UUID)
    for app in host.APPS:
      self.assertIn(f"/data/var/lib/{app} /var/lib/{app}", result)
    self.assertEqual(host.fstab_config(result, UUID), result)

  def test_fstab_rejects_foreign_data_volume_and_bind_source(self):
    for line in (
      "UUID=other /data ext4 defaults 0 2",
      "/different /var/lib/docker none bind 0 0",
      f"UUID={UUID} /data xfs defaults 0 2",
      "/data/var/lib/incus /var/lib/incus none defaults 0 0",
    ):
      with self.subTest(line=line), self.assertRaises(ValueError):
        host.fstab_config(line, UUID, include_runtimes=True)

  def test_mount_verification_checks_the_bind_subdirectory(self):
    good = {
      "target": "/var/lib/docker",
      "source": "/dev/sdb[/var/lib/docker]",
      "fstype": "ext4",
      "fsroot": "/var/lib/docker",
    }
    host.verify_mount(good, Path("/dev/sdb"), "/var/lib/docker")
    for changed in ({"source": "/dev/sda1"}, {"fstype": "xfs"}, {"fsroot": "/"}):
      with self.subTest(changed=changed), self.assertRaises(ValueError):
        host.verify_mount(
          {**good, **changed}, Path("/dev/sdb"), "/var/lib/docker"
        )

  def test_does_not_hide_existing_runtime_data_or_follow_symlinks(self):
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory)
      host.empty_directory(path)
      (path / "database").write_text("important")
      with self.assertRaises(ValueError):
        host.empty_directory(path)
      (path / "link").symlink_to(path)
      with self.assertRaises(ValueError):
        host.empty_directory(path / "link")

  def test_partitioned_or_mounted_system_disk_is_never_formatted(self):
    for children, target in (
      ([{"name": "/dev/sdb1", "type": "part"}], None),
      (None, "/"),
    ):

      def fake_output(command, *args):
        if command == "lsblk":
          return json.dumps(
            {
              "blockdevices": [
                {
                  "name": "/dev/sdb",
                  "type": "disk",
                  "children": children,
                }
              ]
            }
          )
        if command == "findmnt":
          return json.dumps(
            {
              "filesystems": [
                {
                  "target": target,
                  "source": "/dev/sdb",
                  "fstype": "ext4",
                  "fsroot": "/",
                }
              ]
            }
          )
        self.fail(f"Unexpected command {command}")

      with self.subTest(children=children, target=target), patch.object(
        Path, "exists", return_value=True
      ), patch.object(
        Path, "resolve", return_value=Path("/dev/sdb")
      ), patch.object(
        Path, "stat"
      ) as disk_stat, patch.object(
        host, "output", side_effect=fake_output
      ), patch.object(
        host, "run"
      ) as mutate:
        disk_stat.return_value.st_mode = stat.S_IFBLK
        with self.assertRaises(ValueError):
          host.prepare_storage("/dev/oracleoci/oraclevdb", timeout=0)
        mutate.assert_not_called()

  def test_foreign_filesystem_is_never_formatted(self):
    def fake_output(command, *args):
      if command == "lsblk":
        return '{"blockdevices":[{"name":"/dev/sdb","type":"disk"}]}'
      if command == "findmnt":
        return '{"filesystems":[]}'
      if command == "wipefs":
        return '{"signatures":[{"type":"xfs"}]}'
      self.fail(f"Unexpected command {command}")

    with patch.object(Path, "exists", return_value=True), patch.object(
      Path, "resolve", return_value=Path("/dev/sdb")
    ), patch.object(Path, "stat") as disk_stat, patch.object(
      host, "empty_directory"
    ), patch.object(
      host, "output", side_effect=fake_output
    ), patch.object(
      host, "run"
    ) as mutate:
      disk_stat.return_value.st_mode = stat.S_IFBLK
      with self.assertRaisesRegex(ValueError, "signatures"):
        host.prepare_storage("/dev/oracleoci/oraclevdb", timeout=0)
      mutate.assert_not_called()

  def test_missing_attachment_times_out_without_changes(self):
    with patch.object(Path, "exists", return_value=False), patch.object(
      host, "run"
    ) as mutate:
      with self.assertRaisesRegex(ValueError, "Timed out"):
        host.prepare_storage("/missing", timeout=0)
      mutate.assert_not_called()

  def test_blank_disk_setup_then_retry_reuses_uuid_and_mounts(self):
    self.check_storage_layout(include_runtimes=True)

  def test_required_storage_does_not_touch_runtime_directories(self):
    self.check_storage_layout(include_runtimes=False)

  def check_storage_layout(self, include_runtimes):
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      disk = root / "disk"
      disk.touch()
      (root / "etc").mkdir()
      (root / "etc/fstab").write_text("LABEL=root / ext4 defaults 0 1\n")
      existing_data = root / "var/lib/docker/existing-data"
      if not include_runtimes:
        existing_data.parent.mkdir(parents=True)
        existing_data.write_text("keep this")
      mounts, calls = {}, []
      formatted = False

      def local_path(value):
        value = str(value)
        if value.startswith(("/etc/", "/var/", "/data")):
          return root / value.lstrip("/")
        return Path(value)

      def fake_output(command, *args):
        if command == "lsblk":
          return json.dumps(
            {"blockdevices": [{"name": str(disk), "type": "disk"}]}
          )
        if command == "findmnt":
          selected = (
            [mounts[args[2]]]
            if "--mountpoint" in args
            else list(mounts.values())
          )
          return json.dumps({"filesystems": selected})
        if command == "wipefs":
          return json.dumps(
            {"signatures": [{"type": "ext4"}] if formatted else []}
          )
        if command == "blkid":
          return UUID
        self.fail(f"Unexpected command {command}")

      def fake_run(command, *args, **kwargs):
        nonlocal formatted
        calls.append((command, *args))
        if command == "mkfs.ext4":
          formatted = True
        elif command == "mount":
          target = args[-1]
          mounts[target] = {
            "target": target,
            "source": str(disk),
            "fstype": "ext4",
            "fsroot": "/" if target == "/data" else target,
          }
        elif command != "systemctl":
          self.fail(f"Unexpected mutation {command}")

      with patch.object(host, "Path", side_effect=local_path), patch.object(
        host.stat, "S_ISBLK", return_value=True
      ), patch.object(host.uuid_module, "uuid4", return_value=UUID), patch.object(
        host, "output", side_effect=fake_output
      ), patch.object(
        host, "run", side_effect=fake_run
      ):
        host.prepare_storage(
          str(disk), timeout=0, include_runtimes=include_runtimes
        )
        first_fstab = (root / "etc/fstab").read_text()
        self.assertEqual(len(mounts), 4 if include_runtimes else 1)
        if not include_runtimes:
          self.assertNotIn("/var/lib/", first_fstab)
          self.assertFalse((root / "data/var").exists())
          self.assertEqual(existing_data.read_text(), "keep this")
        self.assertEqual(sum(call[0] == "mkfs.ext4" for call in calls), 1)
        calls.clear()
        host.prepare_storage(
          str(disk), timeout=0, include_runtimes=include_runtimes
        )
        self.assertFalse(
          any(call[0] in ("mkfs.ext4", "mount") for call in calls)
        )
        self.assertEqual((root / "etc/fstab").read_text(), first_fstab)

  def test_conflicting_fstab_is_detected_before_formatting(self):
    def fake_output(command, *args):
      return {
        "lsblk": '{"blockdevices":[{"type":"disk"}]}',
        "findmnt": '{"filesystems":[]}',
        "wipefs": '{"signatures":[]}',
      }[command]

    with patch.object(Path, "exists", return_value=True), patch.object(
      Path, "resolve", return_value=Path("/dev/sdb")
    ), patch.object(Path, "stat") as disk_stat, patch.object(
      Path, "read_text", return_value="UUID=foreign /data ext4 defaults 0 2\n"
    ), patch.object(
      host, "empty_directory"
    ), patch.object(
      host, "output", side_effect=fake_output
    ), patch.object(
      host, "run"
    ) as mutate:
      disk_stat.return_value.st_mode = stat.S_IFBLK
      with self.assertRaisesRegex(ValueError, "Conflicting fstab"):
        host.prepare_storage("/dev/oracleoci/oraclevdb", timeout=0)
      mutate.assert_not_called()

  def test_firewall_preserves_oci_protection_and_puts_exceptions_before_reject(self):
    result = host.firewall_config(FIREWALL)
    for line in FIREWALL.splitlines():
      self.assertIn(line, result.splitlines())
    for chain, rule in host.INCUS_RULES:
      self.assertLess(
        result.index(f"-A {chain} {rule}"),
        result.index(f"-A {chain} -j REJECT"),
      )
    self.assertEqual(host.firewall_config(result), result)
    self.assertNotIn("DOCKER", result)

  def test_firewall_accepts_rules_saved_with_explicit_protocol_modules(self):
    current = host.firewall_config(FIREWALL).replace(
      "-p udp --", "-p udp -m udp --"
    )
    current = current.replace("-p tcp --dport 53", "-p tcp -m tcp --dport 53")
    self.assertEqual(host.firewall_config(current), current)

  def test_firewall_refuses_an_unexpected_base(self):
    with self.assertRaises(ValueError):
      host.firewall_config(FIREWALL.replace(":InstanceServices - [0:0]\n", ""))

  def test_firewall_repairs_duplicate_rules_placed_after_rejection(self):
    for verdict in ("REJECT --reject-with icmp-host-prohibited", "DROP"):
      misplaced = FIREWALL.replace(
        "REJECT --reject-with icmp-host-prohibited", verdict
      )
      duplicates = (
        "\n".join(f"-A {chain} {rule}" for chain, rule in host.INCUS_RULES)
        + "\n"
      )
      misplaced = misplaced.replace("COMMIT", duplicates * 2 + "COMMIT")
      result = host.firewall_config(misplaced)
      for chain, rule in host.INCUS_RULES:
        desired = f"-A {chain} {rule}"
        self.assertEqual(result.count(desired), 1)
        self.assertLess(
          result.index(desired), result.index(f"-A {chain} -j {verdict}")
        )
      self.assertEqual(host.firewall_config(result), result)

  def test_live_rule_repair_retains_docker_chain_order(self):
    rule = "-i incusbr0 -j ACCEPT"
    current = (
      "-P FORWARD ACCEPT\n-A FORWARD -j DOCKER-USER\n"
      "-A FORWARD -j DOCKER-FORWARD\n"
      "-A FORWARD -j REJECT --reject-with icmp-host-prohibited\n"
      f"-A FORWARD {rule}\n"
    )
    with patch.object(host, "output", return_value=current), patch.object(
      host, "run"
    ) as mutate:
      host.ensure_live_rule("FORWARD", rule)
      self.assertEqual(mutate.call_count, 2)
      self.assertEqual(
        mutate.call_args_list[0].args,
        (
          "iptables",
          "--wait",
          "-D",
          "FORWARD",
          "-i",
          "incusbr0",
          "-j",
          "ACCEPT",
        ),
      )
      self.assertEqual(
        mutate.call_args_list[1].args,
        (
          "iptables",
          "--wait",
          "-I",
          "FORWARD",
          "3",
          "-i",
          "incusbr0",
          "-j",
          "ACCEPT",
        ),
      )

  def test_live_rule_already_before_rejection_needs_no_changes(self):
    rule = "-i incusbr0 -j ACCEPT"
    current = (
      f"-A FORWARD -j DOCKER-USER\n-A FORWARD {rule}\n"
      "-A FORWARD -j REJECT --reject-with icmp-host-prohibited\n"
    )
    with patch.object(host, "output", return_value=current), patch.object(
      host, "run"
    ) as mutate:
      host.ensure_live_rule("FORWARD", rule)
      mutate.assert_not_called()

  def test_live_rule_without_rejection_is_appended_after_existing_chains(self):
    with patch.object(
      host, "output", return_value="-A FORWARD -j DOCKER-USER\n"
    ), patch.object(host, "run") as mutate:
      host.ensure_live_rule("FORWARD", "-i incusbr0 -j ACCEPT")
      mutate.assert_called_once_with(
        "iptables", "--wait", "-A", "FORWARD", "-i", "incusbr0", "-j", "ACCEPT"
      )

  def test_docker_config_preserves_custom_options_and_original_backup(self):
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "daemon.json"
      original = '{"default-address-pools":[{"base":"172.30.0.0/16","size":24}]}'
      path.write_text(original)

      def local_path(value):
        return path if str(value) == "/etc/docker/daemon.json" else Path(value)

      with patch.object(host, "Path", side_effect=local_path):
        host.configure_docker()
        first = path.read_text()
        host.configure_docker()
      config = json.loads(first)
      self.assertEqual(
        config["default-address-pools"],
        json.loads(original)["default-address-pools"],
      )
      self.assertTrue(config["ip-forward-no-drop"])
      self.assertTrue(config["live-restore"])
      self.assertEqual(config["log-driver"], "local")
      self.assertEqual(path.read_text(), first)
      self.assertEqual(
        path.with_name("daemon.json.oci-host.bak").read_text(),
        original,
      )

  def test_matching_incus_state_is_reused_without_mutation(self):
    with patch.object(host, "output", side_effect=self.incus_output), patch.object(
      host, "run"
    ) as mutate:
      host.configure_incus()
      mutate.assert_not_called()

  def test_conflicting_incus_state_is_not_overwritten(self):
    for endpoint, change in (
      ("/1.0/storage-pools/default", {"driver": "zfs"}),
      ("/1.0/networks/incusbr0", {"config": {"ipv4.address": "10.55.0.1/24"}}),
      (
        "/1.0/profiles/default",
        {"devices": {"root": {"type": "disk", "pool": "other"}}},
      ),
    ):

      def conflict_output(*args):
        result = self.incus_output(*args)
        if args[-1] == endpoint:
          return json.dumps({**json.loads(result), **change})
        return result

      with self.subTest(endpoint=endpoint), patch.object(
        host, "output", side_effect=conflict_output
      ), patch.object(host, "run") as mutate:
        with self.assertRaisesRegex(ValueError, "refusing to change"):
          host.configure_incus()
        mutate.assert_not_called()

  @staticmethod
  def incus_output(*args):
    if args[1:3] in (("storage", "list"), ("network", "list")):
      return json.dumps(
        [{"name": "default" if args[1] == "storage" else "incusbr0"}]
      )
    return json.dumps(
      {
        "/1.0/storage-pools/default": {
          "driver": "dir",
          "config": {"source": "/var/lib/incus/storage-pools/default"},
        },
        "/1.0/networks/incusbr0": {
          "managed": True,
          "type": "bridge",
          "config": {
            "ipv4.address": "10.10.0.1/24",
            "ipv4.nat": "true",
            "ipv6.address": "none",
          },
        },
        "/1.0/profiles/default": {
          "devices": {
            "root": {"type": "disk", "path": "/", "pool": "default"},
            "eth0": {"type": "nic", "name": "eth0", "network": "incusbr0"},
          }
        },
      }[args[-1]]
    )


if __name__ == "__main__":
  unittest.main()
