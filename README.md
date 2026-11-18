<!-- ABOUTME: README for the OCI Always Free ARM Terraform stack. -->
<!-- ABOUTME: Covers quick start, configuration, free-tier limits, and teardown. -->

# oci-alwaysfree-tf-stack

Terraform stack that provisions an Always Free ARM instance on Oracle Cloud, with VCN, subnet, and internet gateway. Auto-discovers the availability domain and latest Ubuntu 26.04 image so you don't need to look up region-specific OCIDs. The selected region must offer an Ubuntu 26.04 image compatible with `VM.Standard.A1.Flex`.

---

## What this builds

* 1 VCN
* 1 Public Subnet
* 1 Internet Gateway
* A managed default security list allowing SSH (TCP port 22) from `0.0.0.0/0`
* Up to 4 ARM Compute Instances
* Up to 24GB Memory
* A 50 GB boot volume and an attached 150 GB block volume, both at 120 VPUs per GB

---

## Prerequisites

* An active OCI account ([sign up for Always Free](https://www.oracle.com/cloud/free/)).
* [Terraform](https://developer.hashicorp.com/terraform/install) installed.
* OCI CLI installed and configured with API keys — see Oracle's [Required Keys and OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm) guide for the full walkthrough. Quick version:
  ```bash
  uv tool install oci-cli   # or: pipx install oci-cli
  oci setup config           # generates ~/.oci/config + API key pair
  # Then upload ~/.oci/oci_api_key_public.pem to:
  # OCI Console → Profile → My profile → API keys → Add API key
  ```
* An SSH key pair (`ssh-keygen -t ed25519` if you don't have one).

---

## Quick Start / How to Use

1. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` — only two values are required:
   ```bash
   # Find your compartment (tenancy) OCID:
   oci iam compartment list --query 'data[0]."compartment-id"' --raw-output

   # List available regions:
   oci iam region list --query 'data[*].name' --raw-output
   ```

3. Run the preflight check to catch config issues before they become cryptic Terraform errors:
   ```bash
   ./preflight.sh
   ```

4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

---

## File Structure

```
oci-alwaysfree-tf-stack/
├── main.tf                  # Provider, data sources, networking, compute
├── variables.tf             # Input variables (2 required, 8 with defaults)
├── outputs.tf               # IPs, OCIDs for downstream use
├── terraform.tfvars.example # Copy to terraform.tfvars and fill in
├── preflight.sh             # Pre-deploy validation (OCI auth, keys, config)
└── .gitignore               # Ignores tfstate, .terraform/, and tfvars
```

---

## Configuration

Only `compartment_id` and `region` are required. Everything else has sensible defaults.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `compartment_id` | `string` | *required* | OCID of the compartment (usually your tenancy OCID) |
| `region` | `string` | *required* | OCI region identifier (e.g., `us-chicago-1`) |
| `availability_domain_index` | `number` | `0` | Index into the AD list. Change if your preferred AD is full. |
| `ssh_public_key` | `string` | `null` | SSH public key string. If null, reads from `ssh_public_key_path`. |
| `ssh_public_key_path` | `string` | `~/.ssh/id_ed25519.pub` | Path to SSH public key file (used when `ssh_public_key` is null) |
| `name_prefix` | `string` | `"oci-arm"` | Prefix for resource display names and DNS labels |
| `ocpus` | `number` | `4` | ARM OCPUs (Always Free max: 4 total) |
| `memory_in_gbs` | `number` | `24` | Memory in GB (Always Free max: 24 total) |
| `boot_volume_size_in_gbs` | `number` | `50` | Boot volume in GB (Always Free max: 200 total) |
| `assign_public_ip` | `bool` | `true` | Keep a public IP for SSH and outbound Internet access through the Internet Gateway |

---

## Accessing the Instance

**SSH in** once the instance is running:
   ```bash
   ssh -i ~/.ssh/your-key ubuntu@$(terraform output -raw instance_public_ip)
   ```

The security list allows TCP port 22 from any IPv4 address (`0.0.0.0/0`). Authenticate with the private key matching the configured SSH public key.

## Storage

The OS boot volume defaults to 50 GB at 120 VPUs per GB. A separate 150 GB block volume at 120 VPUs per GB is attached to the instance in the same availability domain using an encrypted paravirtualized attachment. Retrieve its OCID with `terraform output -raw block_volume_id`.

The data volume is attached as a raw disk. After deployment, identify it with `lsblk`, then create a filesystem and mount it before storing files. Terraform does not format the disk or configure a mount point.

120 VPUs per GB is Oracle's Ultra High Performance tier. The current 4-OCPU `VM.Standard.A1.Flex` configuration does not support multipath Ultra High Performance block volume attachments; Oracle requires at least 16 OCPUs on that shape. The requested VPU settings are configured, but actual performance is constrained by the instance and attachment. See [Oracle's performance details](https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/blockvolumeperformance.htm).

---

## Always Free Guardrails

The default storage capacity totals 200 GB across boot and data volumes, matching the home-region Always Free storage allowance when no other volumes consume it. The 120 VPUs per GB performance setting is separate from capacity; confirm your tenancy's billing treatment before applying. See [Oracle's storage allowance](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm#blockvolume) and [volume performance documentation](https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/blockvolumeperformance.htm). If you change resource sizes, check the totals across all your instances:

| Resource | This stack uses | Always Free limit |
|----------|----------------|-------------------|
| ARM OCPUs | 4 | 4 total |
| Memory | 24 GB | 24 GB total |
| Boot + data volumes | 50 GB + 150 GB = 200 GB | 200 GB total |
| Instances | 1 | Up to 4 ARM + 2 AMD |
| VCN | 1 | Included |

**Cost Disclaimer: While this targets the Always Free tier, you are ultimately responsible for checking your OCI billing dashboard to ensure you haven't exceeded limits or selected the wrong region/shapes.**

---

## Tearing Down

```bash
terraform destroy
```

Removes the instance, data block volume and its contents, VCN, subnet, and gateway. Terraform state tracks what was created, so the destroy is clean and complete.

---

## Troubleshooting

- **Intermittent 401-NotAuthenticated from Terraform**: Check that your PEM key file (`~/.oci/oci_api_key.pem`) ends cleanly with `-----END PRIVATE KEY-----` and nothing after it. The OCI CLI's Python SDK tolerates trailing junk, but the Terraform provider's Go SDK does not — it causes random auth failures where some API calls succeed and others don't. The `preflight.sh` script checks for this automatically.

- **"Python X.Y not found" from OCI CLI**: Install with `uv tool install oci-cli` or `pipx install oci-cli` to use an isolated Python environment instead of depending on the system Python.

## Notes

- **OCI authentication**: The provider uses `~/.oci/config` by default. See the [OCI Terraform provider docs](https://registry.terraform.io/providers/oracle/oci/latest/docs) for alternatives (env vars, instance principal, etc.).

- **Public IP lifecycle**: Keep `assign_public_ip = true` in this Internet Gateway topology for public SSH and outbound Internet access.

- **Finding your OCIDs**:
  ```bash
  # Compartment (tenancy OCID)
  oci iam compartment list --query 'data[0]."compartment-id"' --raw-output

  # Available regions
  oci iam region list --query 'data[*].name' --raw-output
  ```
