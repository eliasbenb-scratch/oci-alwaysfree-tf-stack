terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }
}

provider "oci" {
  region = var.region
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "26.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  image_id            = data.oci_core_images.ubuntu.images[0].id
  dns_prefix          = replace(lower(var.name_prefix), "/[^a-z0-9]/", "")
  data_device         = "/dev/oracleoci/oraclevdb"

  host_files = concat(
    [
      {
        path        = "/usr/local/lib/oci-host/host_config.py"
        permissions = "0644"
        content     = file("${path.module}/scripts/host_config.py")
      },
      {
        path        = "/etc/oci-host.json"
        permissions = "0644"
        content = jsonencode({
          data_device = local.data_device
          admin_user  = "ubuntu"
        })
      }
    ],
    var.bootstrap_host ? [
      {
        path        = "/usr/local/sbin/bootstrap-host"
        permissions = "0755"
        content     = file("${path.module}/scripts/bootstrap.sh")
      }
    ] : []
  )

  host_commands = concat(
    ["/usr/bin/python3 /usr/local/lib/oci-host/host_config.py storage"],
    var.bootstrap_host ? ["/usr/local/sbin/bootstrap-host"] : []
  )

  host_cloud_config = "#cloud-config\n${yamlencode({
    write_files = local.host_files
    # A storage failure must stop the optional bootstrap as well.
    runcmd = [["/bin/sh", "-ec", join("\n", local.host_commands)]]
  })}"
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "${local.dns_prefix}vcn"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
}

resource "oci_core_default_route_table" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_route_table_id
  display_name               = "${var.name_prefix}-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  display_name               = "${var.name_prefix}-security-list"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
    description      = "Allow outbound IPv4 traffic"
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "1"
    stateless   = false
    description = "Path MTU discovery"

    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    source      = oci_core_vcn.this.cidr_block
    source_type = "CIDR_BLOCK"
    protocol    = "1"
    stateless   = false
    description = "ICMP destination unreachable within the VCN"

    icmp_options {
      type = 3
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    stateless   = false
    description = "Public SSH access"

    tcp_options {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  cidr_block     = "10.0.0.0/24"
  display_name   = "${var.name_prefix}-subnet"
  dns_label      = "${local.dns_prefix}sub"
  route_table_id = oci_core_vcn.this.default_route_table_id
}

resource "oci_core_instance" "this" {
  compartment_id       = var.compartment_id
  availability_domain  = local.availability_domain
  display_name         = var.name_prefix
  shape                = "VM.Standard.A1.Flex"
  preserve_boot_volume = false

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
    boot_volume_vpus_per_gb = var.volume_vpus_per_gb
  }

  create_vnic_details {
    subnet_id                 = oci_core_subnet.this.id
    assign_public_ip          = false
    assign_private_dns_record = true
    assign_ipv6ip             = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.host_cloud_config)
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  is_pv_encryption_in_transit_enabled = true

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false

    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Custom Logs Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Cloud Guard Workload Protection"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Vulnerability Scanning"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Management Agent"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Block Volume Management"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute RDMA GPU Monitoring"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute HPC RDMA Auto-Configuration"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute HPC RDMA Authentication"
      desired_state = "DISABLED"
    }
  }
}

data "oci_core_vnic_attachments" "this" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.this.id
}

data "oci_core_private_ips" "this" {
  vnic_id = one(data.oci_core_vnic_attachments.this.vnic_attachments).vnic_id
}

resource "oci_core_public_ip" "this" {
  count = var.assign_public_ip ? 1 : 0

  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-public-ip"
  lifetime       = "EPHEMERAL"
  private_ip_id  = one(data.oci_core_private_ips.this.private_ips).id
}

resource "oci_core_volume" "data" {
  compartment_id      = var.compartment_id
  availability_domain = local.availability_domain
  display_name        = "${var.name_prefix}-data"
  size_in_gbs         = var.block_volume_size_in_gbs
  vpus_per_gb         = var.volume_vpus_per_gb
}

resource "oci_core_volume_attachment" "data" {
  attachment_type                     = "paravirtualized"
  device                              = local.data_device
  instance_id                         = oci_core_instance.this.id
  volume_id                           = oci_core_volume.data.id
  is_read_only                        = false
  is_shareable                        = false
  is_pv_encryption_in_transit_enabled = true
}
