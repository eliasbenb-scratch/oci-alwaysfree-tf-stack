mock_provider "oci" {}

override_data {
  target = data.oci_identity_availability_domains.ads
  values = {
    availability_domains = [{ name = "AD-1" }]
  }
}

override_data {
  target = data.oci_core_images.ubuntu
  values = {
    images = [{ id = "ocid1.image.oc1.example", display_name = "Canonical-Ubuntu-26.04-aarch64-2026.11.01-0" }]
  }
}

override_data {
  target = data.oci_core_vnic_attachments.this
  values = {
    vnic_attachments = [{ vnic_id = "ocid1.vnic.oc1.example" }]
  }
}

override_data {
  target = data.oci_core_private_ips.this
  values = {
    private_ips = [{ id = "ocid1.privateip.oc1.example" }]
  }
}

variables {
  compartment_id = "ocid1.tenancy.oc1..example"
  region         = "us-chicago-1"
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest hermes-test"
}

run "public_ssh_access" {
  command = plan

  assert {
    condition     = length([for rule in oci_core_default_security_list.this.ingress_security_rules : rule if rule.protocol == "6"]) == 1 && one([for rule in oci_core_default_security_list.this.ingress_security_rules : rule if rule.protocol == "6"]).source == "0.0.0.0/0"
    error_message = "Exactly one TCP ingress rule must allow public IPv4 SSH access."
  }

  assert {
    condition     = one(one([for rule in oci_core_default_security_list.this.ingress_security_rules : rule if rule.protocol == "6"]).tcp_options).min == 22 && one(one([for rule in oci_core_default_security_list.this.ingress_security_rules : rule if rule.protocol == "6"]).tcp_options).max == 22
    error_message = "The public TCP rule must allow only destination port 22."
  }

  assert {
    condition     = length([for rule in oci_core_default_security_list.this.ingress_security_rules : rule if rule.protocol == "17"]) == 0
    error_message = "No UDP ingress rules should be configured."
  }

  assert {
    condition     = length([for rule in oci_core_default_security_list.this.ingress_security_rules : rule if rule.protocol == "1"]) == 2
    error_message = "Both OCI default ICMP ingress rules must remain present."
  }

  assert {
    condition     = length(oci_core_default_security_list.this.egress_security_rules) == 1 && one(oci_core_default_security_list.this.egress_security_rules).destination == "0.0.0.0/0"
    error_message = "Unrestricted IPv4 egress must remain present."
  }

  assert {
    condition     = !oci_core_instance.this.create_vnic_details[0].assign_public_ip && oci_core_public_ip.this[0].lifetime == "EPHEMERAL"
    error_message = "The reference deployment must attach an explicitly managed ephemeral public IP."
  }

  assert {
    condition     = oci_core_instance.this.source_details[0].boot_volume_size_in_gbs == "50"
    error_message = "The default boot volume must meet OCI's 50 GB minimum."
  }

  assert {
    condition     = !oci_core_instance.this.preserve_boot_volume
    error_message = "Destroying the instance must also delete its boot volume."
  }
}

run "rejects_boot_volume_below_oci_minimum" {
  command = plan

  variables {
    boot_volume_size_in_gbs = 49
  }

  expect_failures = [var.boot_volume_size_in_gbs]
}

run "rejects_block_volume_below_oci_minimum" {
  command = plan

  variables {
    block_volume_size_in_gbs = 49
  }

  expect_failures = [var.block_volume_size_in_gbs]
}

run "rejects_invalid_volume_vpus" {
  command = plan

  variables {
    volume_vpus_per_gb = 15
  }

  expect_failures = [var.volume_vpus_per_gb]
}

run "volume_settings_are_shared" {
  command = plan

  variables {
    block_volume_size_in_gbs = 100
    volume_vpus_per_gb       = 40
  }

  assert {
    condition     = oci_core_instance.this.source_details[0].boot_volume_vpus_per_gb == "40" && oci_core_volume.data.size_in_gbs == "100" && oci_core_volume.data.vpus_per_gb == "40"
    error_message = "The configured VPU setting must apply to both volumes, and the block volume size must be configurable."
  }
}

run "rejects_empty_ssh_public_key" {
  command = plan

  variables {
    ssh_public_key = ""
  }

  expect_failures = [var.ssh_public_key]
}

run "rejects_blank_ssh_public_key" {
  command = plan

  variables {
    ssh_public_key = "   "
  }

  expect_failures = [var.ssh_public_key]
}

run "storage_configuration" {
  command = plan

  override_resource {
    target          = oci_core_instance.this
    override_during = plan
    values          = { id = "ocid1.instance.oc1.example" }
  }

  override_resource {
    target          = oci_core_volume.data
    override_during = plan
    values          = { id = "ocid1.volume.oc1.example" }
  }

  assert {
    condition     = oci_core_instance.this.source_details[0].boot_volume_size_in_gbs == "50" && oci_core_instance.this.source_details[0].boot_volume_vpus_per_gb == "10"
    error_message = "The boot volume must default to 50 GB and use 10 VPUs per GB."
  }

  assert {
    condition     = oci_core_volume.data.size_in_gbs == "150" && oci_core_volume.data.vpus_per_gb == "10"
    error_message = "The data volume must default to 150 GB at 10 VPUs per GB."
  }

  assert {
    condition     = oci_core_volume.data.availability_domain == oci_core_instance.this.availability_domain && oci_core_volume.data.compartment_id == var.compartment_id
    error_message = "The data volume must be in the instance's availability domain and compartment."
  }

  assert {
    condition     = oci_core_volume_attachment.data.instance_id == oci_core_instance.this.id && oci_core_volume_attachment.data.volume_id == oci_core_volume.data.id
    error_message = "The data volume must attach to the instance."
  }

  assert {
    condition     = oci_core_volume_attachment.data.attachment_type == "paravirtualized" && oci_core_volume_attachment.data.is_pv_encryption_in_transit_enabled && !oci_core_volume_attachment.data.is_read_only && !oci_core_volume_attachment.data.is_shareable
    error_message = "The data volume must use an encrypted, read/write, single-instance paravirtualized attachment."
  }

  assert {
    condition     = oci_core_volume_attachment.data.device == "/dev/oracleoci/oraclevdb"
    error_message = "The attachment must use the same explicit device name as bootstrap."
  }
}

run "host_cloud_init" {
  command = plan

  assert {
    condition     = startswith(base64decode(oci_core_instance.this.metadata.user_data), "#cloud-config\n")
    error_message = "The instance must receive a cloud-config document."
  }

  assert {
    condition     = yamldecode(base64decode(oci_core_instance.this.metadata.user_data)).runcmd == [["/bin/sh", "-ec", "/usr/bin/python3 /usr/local/lib/oci-host/host_config.py storage\n/usr/local/sbin/bootstrap-host"]]
    error_message = "Cloud-init must prepare /data before running the optional bootstrap, stopping on failure."
  }

  assert {
    condition     = jsondecode(one([for f in local.host_files : f.content if f.path == "/etc/oci-host.json"])).data_device == oci_core_volume_attachment.data.device
    error_message = "The guest must wait for the device Terraform actually attaches."
  }

  assert {
    condition     = length(oci_core_instance.this.metadata.user_data) <= 32000
    error_message = "Encoded user_data must fit within OCI's 32 KB metadata limit."
  }
}

run "storage_without_bootstrap" {
  command = plan

  variables {
    bootstrap_host = false
  }

  assert {
    condition     = yamldecode(base64decode(oci_core_instance.this.metadata.user_data)).runcmd == [["/bin/sh", "-ec", "/usr/bin/python3 /usr/local/lib/oci-host/host_config.py storage"]]
    error_message = "Disabling bootstrap must still run the required /data setup."
  }

  assert {
    condition     = !contains([for f in local.host_files : f.path], "/usr/local/sbin/bootstrap-host") && contains([for f in local.host_files : f.path], "/usr/local/lib/oci-host/host_config.py")
    error_message = "Storage setup must be installed without installing the optional bootstrap script."
  }
}
