output "instance_id" {
  description = "OCID of the compute instance"
  value       = oci_core_instance.this.id
}

output "instance_public_ip" {
  description = "Public IP of the instance (empty if assign_public_ip is false)"
  value       = var.assign_public_ip ? oci_core_public_ip.this[0].ip_address : ""
}

output "instance_private_ip" {
  description = "Private IP within the VCN"
  value       = oci_core_instance.this.private_ip
}

output "image_id" {
  description = "OCID of the auto-selected Ubuntu image"
  value       = local.image_id
}

output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.this.id
}

output "subnet_id" {
  description = "OCID of the subnet"
  value       = oci_core_subnet.this.id
}

output "block_volume_id" {
  description = "OCID of the data block volume"
  value       = oci_core_volume.data.id
}
