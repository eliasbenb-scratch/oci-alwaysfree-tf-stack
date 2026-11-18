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
    images = [{ id = "ocid1.image.oc1.example" }]
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
    condition     = data.oci_core_images.ubuntu.operating_system_version == "26.04" && data.oci_core_images.ubuntu.shape == "VM.Standard.A1.Flex"
    error_message = "The image lookup must select Ubuntu 26.04 compatible with the ARM instance shape."
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
    condition     = oci_core_instance.this.create_vnic_details[0].assign_public_ip
    error_message = "The reference deployment must retain its public IP."
  }

  assert {
    condition     = oci_core_instance.this.source_details[0].boot_volume_size_in_gbs == "50"
    error_message = "The default boot volume must meet OCI's 50 GB minimum."
  }
}

run "rejects_boot_volume_below_oci_minimum" {
  command = plan

  variables {
    boot_volume_size_in_gbs = 49
  }

  expect_failures = [var.boot_volume_size_in_gbs]
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
    condition     = oci_core_instance.this.source_details[0].boot_volume_size_in_gbs == "50" && oci_core_instance.this.source_details[0].boot_volume_vpus_per_gb == "120"
    error_message = "The boot volume must remain 50 GB and use 120 VPUs per GB."
  }

  assert {
    condition     = oci_core_volume.data.size_in_gbs == "150" && oci_core_volume.data.vpus_per_gb == "120"
    error_message = "The data volume must provide 150 GB at 120 VPUs per GB."
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
}
