variable "compartment_id" {
  description = "OCID of the compartment (usually your tenancy OCID for Always Free)"
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g., us-chicago-1, eu-frankfurt-1)"
  type        = string
}

variable "availability_domain_index" {
  description = "Index into the list of availability domains (0-based). Change if your preferred AD is full."
  type        = number
  default     = 0
}

variable "ssh_public_key" {
  description = "SSH public key string to authorize on the instance"
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.ssh_public_key)) > 0
    error_message = "ssh_public_key must be a nonempty SSH public key string."
  }
}

variable "name_prefix" {
  description = "Prefix for resource display names and DNS labels"
  type        = string
  default     = "oci-arm"

  validation {
    condition     = length(replace(lower(var.name_prefix), "/[^a-z0-9]/", "")) + 3 <= 15
    error_message = "The sanitized name_prefix plus its suffix must fit the 15-character OCI DNS label limit."
  }
}

variable "ocpus" {
  description = "Number of ARM OCPUs (Always Free max: 4 total across all instances)"
  type        = number
  default     = 4
}

variable "memory_in_gbs" {
  description = "Memory in GB (Always Free max: 24 total across all instances)"
  type        = number
  default     = 24
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB (Always Free max: 200 total across all volumes)"
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs >= 50 && var.boot_volume_size_in_gbs <= 32768
    error_message = "boot_volume_size_in_gbs must be between 50 and 32768 GB."
  }
}

variable "block_volume_size_in_gbs" {
  description = "Data block volume size in GB (Always Free max: 200 GB total across volumes)"
  type        = number
  default     = 150

  validation {
    condition     = var.block_volume_size_in_gbs >= 50 && var.block_volume_size_in_gbs <= 32768
    error_message = "block_volume_size_in_gbs must be between 50 and 32768 GB."
  }
}

variable "volume_vpus_per_gb" {
  description = "Performance units per GB shared by the boot and data block volumes"
  type        = number
  default     = 10

  validation {
    condition     = var.volume_vpus_per_gb >= 0 && var.volume_vpus_per_gb <= 120 && var.volume_vpus_per_gb % 10 == 0
    error_message = "volume_vpus_per_gb must be a multiple of 10 between 0 and 120."
  }
}

variable "assign_public_ip" {
  description = "Assign a public IP for SSH access and outbound Internet access through the Internet Gateway"
  type        = bool
  default     = true
}

variable "bootstrap_host" {
  description = "Run scripts/bootstrap.sh after the required /data setup on first boot"
  type        = bool
  default     = true
  nullable    = false
}
