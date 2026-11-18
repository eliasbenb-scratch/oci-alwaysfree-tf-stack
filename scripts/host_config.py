#!/usr/bin/python3
"""Guest storage and bootstrap configuration."""

import argparse
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import uuid as uuid_module

APPS = ("docker", "containerd", "incus")
INCUS_IPV4_ADDRESS = "10.10.0.1/24"
BEGIN = "# BEGIN oci-host"
END = "# END oci-host"


def run(*args, **kwargs):
  return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
  return run(*args, stdout=subprocess.PIPE).stdout.strip()


def write_file(path, content, mode=None):
  """Keep an original backup and replace atomically, retaining file permissions."""
  path = Path(path)
  if path.exists() and path.read_text() == content:
    return
  path.parent.mkdir(parents=True, exist_ok=True)
  if path.exists():
    mode = mode or stat.S_IMODE(path.stat().st_mode)
    backup = path.with_name(path.name + ".oci-host.bak")
    if not backup.exists():
      backup.write_bytes(path.read_bytes())
      backup.chmod(mode)
  with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as temp:
    temp.write(content)
  os.chmod(temp.name, mode or 0o644)
  os.replace(temp.name, path)


def fstab_config(text, uuid, include_runtimes=False):
  entries = {
    "/data": (f"UUID={uuid}", "ext4", "defaults,_netdev,nofail", "0", "2"),
  }
  if include_runtimes:
    entries.update(
      {
        f"/var/lib/{app}": (
          f"/data/var/lib/{app}",
          "none",
          "bind,_netdev,nofail,x-systemd.requires=/data",
          "0",
          "0",
        )
        for app in APPS
      }
    )
  retained = []
  for line in text.splitlines():
    if line in (BEGIN, END):
      continue
    fields = line.split()
    if fields and not line.lstrip().startswith("#") and len(fields) >= 2:
      target = fields[1]
      if target in entries:
        expected = entries[target]
        if (
          fields[0] != expected[0]
          or len(fields) < 4
          or (target == "/data" and fields[2] != "ext4")
          or (target != "/data" and "bind" not in fields[3].split(","))
        ):
          raise ValueError(f"Conflicting fstab entry for {target}: {line}")
        continue
    retained.append(line)
  block = [BEGIN]
  for target, (source, fs, opts, dump, check) in entries.items():
    block.append(f"{source} {target} {fs} {opts} {dump} {check}")
  return "\n".join(retained).rstrip() + "\n\n" + "\n".join(block) + f"\n{END}\n"


def verify_mount(mount, device, fsroot):
  source = mount["source"].split("[", 1)[0]
  if (
    os.path.realpath(source) != str(device)
    or mount["fstype"] != "ext4"
    or mount["fsroot"] != fsroot
  ):
    raise ValueError(f"Unexpected mount at {mount['target']}: {mount}")


def empty_directory(path):
  path = Path(path)
  if path.is_symlink() or (
    path.exists() and (not path.is_dir() or any(path.iterdir()))
  ):
    raise ValueError(
      f"Refusing to hide existing data at {path}; migrate it offline first"
    )


def prepare_storage(device_name, timeout=600, include_runtimes=False):
  deadline = time.monotonic() + timeout
  while not Path(device_name).exists():
    if time.monotonic() >= deadline:
      raise ValueError(
        f"Timed out waiting for the Terraform volume attachment: {device_name}"
      )
    time.sleep(5)
  device = Path(device_name).resolve(strict=True)
  if not stat.S_ISBLK(device.stat().st_mode):
    raise ValueError(f"Not a block device: {device}")
  disks = json.loads(
    output("lsblk", "--json", "--paths", "--output", "NAME,TYPE", str(device))
  )
  (disk,) = disks["blockdevices"]
  if disk["type"] != "disk" or disk.get("children"):
    raise ValueError(
      "Expected an unpartitioned data disk; refusing to format a disk with partitions"
    )

  mounts = json.loads(
    output("findmnt", "--json", "--list", "--output", "TARGET,SOURCE,FSTYPE,FSROOT")
  )["filesystems"]
  targets = {m["target"]: m for m in mounts}
  allowed_roots = {"/data": "/", **{f"/var/lib/{a}": f"/var/lib/{a}" for a in APPS}}
  expected_roots = allowed_roots if include_runtimes else {"/data": "/"}
  for mount in mounts:
    source = mount["source"].split("[", 1)[0]
    if os.path.realpath(source) == str(device):
      target = mount["target"]
      if target not in allowed_roots and not any(
        target.startswith(base + "/") for base in allowed_roots
      ):
        raise ValueError(f"Data disk is in use at unexpected target {target}")
  for target, root in expected_roots.items():
    if target in targets:
      verify_mount(targets[target], device, root)
    else:
      empty_directory(target)

  signatures = json.loads(output("wipefs", "--json", str(device)))["signatures"]
  types = [sig["type"] for sig in signatures]
  if types and types != ["ext4"]:
    raise ValueError(f"Refusing to overwrite disk signatures: {types}")
  uuid = (
    output("blkid", "-s", "UUID", "-o", "value", str(device))
    if types
    else str(uuid_module.uuid4())
  )
  if not uuid:
    raise ValueError("No filesystem UUID found on the data volume")
  fstab = Path("/etc/fstab")
  updated = fstab_config(fstab.read_text(), uuid, include_runtimes)
  if not types:
    # Validate fstab conflicts before formatting. Never use -F: let mkfs
    # also reject any unexpected device state.
    run("mkfs.ext4", "-m", "1", "-U", uuid, str(device))
  Path("/data").mkdir(exist_ok=True)
  if "/data" not in targets:
    run("mount", "-t", "ext4", "-o", "defaults,_netdev", str(device), "/data")
  if include_runtimes:
    for app in APPS:
      source, target = Path(f"/data/var/lib/{app}"), Path(f"/var/lib/{app}")
      source.mkdir(parents=True, exist_ok=True, mode=0o700)
      target.mkdir(parents=True, exist_ok=True, mode=0o700)
  write_file(fstab, updated)
  run("systemctl", "daemon-reload")
  for target, root in expected_roots.items():
    if target != "/data" and target not in targets:
      run("mount", target)
    (mount,) = json.loads(
      output(
        "findmnt",
        "--json",
        "--mountpoint",
        target,
        "--output",
        "TARGET,SOURCE,FSTYPE,FSROOT",
      )
    )["filesystems"]
    verify_mount(mount, device, root)


INCUS_RULES = (
  ("INPUT", "-i incusbr0 -p udp --dport 67 -j ACCEPT"),
  ("INPUT", "-i incusbr0 -p udp --dport 53 -j ACCEPT"),
  ("INPUT", "-i incusbr0 -p tcp --dport 53 -j ACCEPT"),
  ("FORWARD", "-i incusbr0 -j ACCEPT"),
  ("FORWARD", "-o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"),
)


def normalize_rule(rule):
  # iptables-save adds explicit protocol modules to otherwise equivalent rules.
  return rule.replace(" -m udp", "").replace(" -m tcp", "")


def terminal_rule(rule):
  tokens = shlex.split(rule)
  return any(
    tokens[i : i + 2] in (["-j", "REJECT"], ["-j", "DROP"])
    for i in range(len(tokens) - 1)
  )


def firewall_config(text):
  """Insert only our static rules; never persist Docker's runtime chains."""
  lines = text.splitlines()
  start = lines.index("*filter")
  end = lines.index("COMMIT", start)
  if not any(line.startswith(":InstanceServices ") for line in lines[start:end]):
    raise ValueError("Expected OCI InstanceServices protection in rules.v4")
  for chain, rule in INCUS_RULES:
    desired = f"-A {chain} {rule}"
    matches = [
      i
      for i in range(start + 1, end)
      if normalize_rule(lines[i]) == normalize_rule(desired)
    ]
    reject = next(
      (
        i
        for i in range(start + 1, end)
        if lines[i].startswith(f"-A {chain} ") and terminal_rule(lines[i])
      ),
      end,
    )
    if len(matches) == 1 and matches[0] < reject:
      continue
    # Repair duplicate or unreachable exceptions, retaining unrelated rules.
    for i in reversed(matches):
      del lines[i]
    end -= len(matches)
    index = next(
      (
        i
        for i in range(start + 1, end)
        if lines[i].startswith(f"-A {chain} ") and terminal_rule(lines[i])
      ),
      end,
    )
    lines.insert(index, desired)
    end += 1
  return "\n".join(lines) + "\n"


def ensure_live_rule(chain, rule):
  rules = [
    line
    for line in output("iptables", "--wait", "-S", chain).splitlines()
    if line.startswith(f"-A {chain} ")
  ]
  desired = f"-A {chain} {rule}"
  matches = [
    i
    for i, line in enumerate(rules)
    if normalize_rule(line) == normalize_rule(desired)
  ]
  reject = next(
    (i for i, line in enumerate(rules) if terminal_rule(line)), len(rules)
  )
  if len(matches) == 1 and matches[0] < reject:
    return
  for i in reversed(matches):
    run("iptables", "--wait", "-D", chain, *shlex.split(rules[i])[2:])
    del rules[i]
  # Respect Docker's existing chains; insert just before the OCI rejection.
  reject = next((i for i, line in enumerate(rules) if terminal_rule(line)), None)
  args = shlex.split(rule)
  if reject is None:
    run("iptables", "--wait", "-A", chain, *args)
  else:
    run("iptables", "--wait", "-I", chain, str(reject + 1), *args)


def configure_firewall():
  path = Path("/etc/iptables/rules.v4")
  updated = firewall_config(path.read_text())
  # --test validates without flushing running Docker/Incus rules.
  run("iptables-restore", "--test", input=updated)
  write_file(path, updated)
  for chain, rule in INCUS_RULES:
    ensure_live_rule(chain, rule)


def configure_docker():
  path = Path("/etc/docker/daemon.json")
  config = json.loads(path.read_text()) if path.exists() else {}
  config.update(
    {"ip-forward-no-drop": True, "live-restore": True, "log-driver": "local"}
  )
  write_file(path, json.dumps(config, indent=2) + "\n")


def configure_incus():
  pools = json.loads(output("incus", "storage", "list", "--format=json"))
  if not any(p["name"] == "default" for p in pools):
    run(
      "incus",
      "storage",
      "create",
      "default",
      "dir",
      "source=/var/lib/incus/storage-pools/default",
    )
  pool = json.loads(output("incus", "query", "/1.0/storage-pools/default"))
  if (
    pool["driver"] != "dir"
    or pool["config"].get("source") != "/var/lib/incus/storage-pools/default"
  ):
    raise ValueError("Existing default Incus pool differs; refusing to change it")
  networks = json.loads(output("incus", "network", "list", "--format=json"))
  if not any(n["name"] == "incusbr0" for n in networks):
    run(
      "incus",
      "network",
      "create",
      "incusbr0",
      f"ipv4.address={INCUS_IPV4_ADDRESS}",
      "ipv4.nat=true",
      "ipv6.address=none",
    )
  network = json.loads(output("incus", "query", "/1.0/networks/incusbr0"))
  expected = {
    "ipv4.address": INCUS_IPV4_ADDRESS,
    "ipv4.nat": "true",
    "ipv6.address": "none",
  }
  if (
    not network["managed"]
    or network["type"] != "bridge"
    or any(network["config"].get(k) != v for k, v in expected.items())
  ):
    raise ValueError(
      "Existing incusbr0 configuration differs; refusing to change it"
    )
  profile = json.loads(output("incus", "query", "/1.0/profiles/default"))
  for name, desired in {
    "root": {"type": "disk", "path": "/", "pool": "default"},
    "eth0": {"type": "nic", "name": "eth0", "network": "incusbr0"},
  }.items():
    current = profile["devices"].get(name)
    if current is None:
      run(
        "incus",
        "profile",
        "device",
        "add",
        "default",
        name,
        desired["type"],
        *(f"{k}={v}" for k, v in desired.items() if k != "type"),
      )
    elif any(current.get(k) != v for k, v in desired.items()):
      raise ValueError(
        f"Existing default profile device {name} differs; refusing to change it"
      )


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument(
    "action",
    choices=("storage", "runtime-storage", "docker", "firewall", "incus", "access"),
  )
  action = parser.parse_args().action
  try:
    config = json.loads(Path("/etc/oci-host.json").read_text())
    if action == "storage":
      prepare_storage(config["data_device"])
      write_file("/var/lib/oci-host/storage-ready", "")
    elif action == "runtime-storage":
      prepare_storage(config["data_device"], include_runtimes=True)
    elif action == "firewall":
      configure_firewall()
    elif action == "docker":
      configure_docker()
    elif action == "incus":
      configure_incus()
    elif action == "access":
      run("usermod", "-aG", "docker,incus-admin", config["admin_user"])
  except (ValueError, OSError, subprocess.CalledProcessError) as exc:
    sys.exit(f"oci-host: {exc}")


if __name__ == "__main__":
  main()
