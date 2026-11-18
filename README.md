# OCI ARM stack

An Ubuntu 26.04 ARM instance on Oracle Cloud Infrastructure. The defaults are 4 OCPUs, 24 GB RAM, a 50 GB boot volume, and a 150 GB data volume.

The guest always prepares the data volume and mounts it at `/data`. `bootstrap_host` controls whether it then runs [scripts/bootstrap.sh](scripts/bootstrap.sh). The supplied script installs Docker CE and Zabbly Incus 7.0 LTS.

## Deploy

Install Terraform and the OCI CLI, configure API credentials with `oci setup config`, and create an SSH key pair. See Oracle's [API key setup guide](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm).

Copy the example and fill in `compartment_id`, `region`, and `ssh_public_key`:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Use the full SSH public key as a quoted string. Keep the private key locally.

```bash
./scripts/preflight.sh
terraform init
terraform plan
terraform apply
```

Wait for guest setup after Terraform finishes:

```bash
ssh ubuntu@$(terraform output -raw instance_public_ip) 'sudo cloud-init status --wait --long'
```

The region must offer an Ubuntu 26.04 image for `VM.Standard.A1.Flex`. Direct SSH and outbound access through the Internet Gateway need a public IP.

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `compartment_id` | Required | OCI compartment or tenancy OCID |
| `region` | Required | OCI region, such as `us-chicago-1` |
| `ssh_public_key` | Required | Public key authorized for SSH |
| `availability_domain_index` | `0` | Availability domain index |
| `name_prefix` | `"oci-arm"` | Resource names and DNS labels |
| `ocpus` | `4` | ARM OCPUs |
| `memory_in_gbs` | `24` | RAM in GB |
| `boot_volume_size_in_gbs` | `50` | Boot volume size in GB |
| `block_volume_size_in_gbs` | `150` | Data block volume size in GB |
| `volume_vpus_per_gb` | `10` | Performance units per GB shared by both volumes |
| `assign_public_ip` | `true` | Assign a public IPv4 address |
| `bootstrap_host` | `true` | Run the optional bootstrap script after mounting `/data` |

`bootstrap_host = false` skips the script. It does not skip disk preparation or undo an earlier bootstrap. Change the script to customize host setup.

The VCN uses `10.0.0.0/16`; its subnet uses `10.0.0.0/24`. The bootstrap's Incus bridge uses `10.10.0.1/24`. That address is fixed in the helper and does not overlap the VCN or Docker's default pools.

## Guest setup

Cloud-init is defined in [main.tf](main.tf). It runs storage setup first and stops on failure. With bootstrap enabled, the script adds runtime bind mounts for Docker, containerd, and Incus, then installs the packages. The data volume is mounted at `/data`; runtime services require their bind mounts before they start. Incus uses `incusbr0` at `10.10.0.1/24`, with IPv4 NAT and IPv6 disabled.

The attachment uses `/dev/oracleoci/oraclevdb`; fstab uses the filesystem UUID. Changing an existing attachment's device can require detach/reattach. Review the plan before applying to an existing deployment. Updating metadata does not rerun cloud-init on an existing instance.

Existing containers and application data are not recreated by the stack.

## Capacity and performance

The defaults consume the home-region Always Free capacity allowance of 4 ARM OCPUs, 24 GB RAM, and 200 GB combined boot/data storage if no other resources are using it.

Both volumes use the shared `volume_vpus_per_gb` setting. The default of 10 VPUs/GB is Balanced Performance.

## Development

The Terraform resources and cloud-init metadata are in [main.tf](main.tf). Guest configuration lives under [scripts/](scripts/). The tests use a mocked OCI provider and simulated disk commands.

With Terraform, Python 3, Bats, ShellCheck, and GNU Make installed:

```bash
terraform init -backend=false
make check
```

`make format` formats Terraform. Indentation uses two spaces. Make recipes use `>` as their prefix so the Makefile does not need tabs.

A disposable OCI deployment and reboot are needed to test the full boot path. The local tests do not create infrastructure or format real disks.

## Troubleshooting

Run `./scripts/preflight.sh` to check OCI authentication and the SSH key configuration. For intermittent 401 responses, check for trailing content after the private PEM file's closing footer. If the OCI CLI has Python dependency errors, install it with `uv tool install oci-cli` or `pipx install oci-cli`.

For guest setup failures, inspect cloud-init and the data mount first:

```bash
sudo cloud-init status --long
sudo tail -n 100 /var/log/cloud-init-output.log
lsblk -f
findmnt --mountpoint /data
```

Retry storage with `/usr/bin/python3 /usr/local/lib/oci-host/host_config.py storage` or retry the optional bootstrap with `/usr/local/sbin/bootstrap-host` after fixing the cause. The scripts refuse to format disks with existing partitions or unknown filesystem signatures.

The bootstrap retries apt lock contention for up to five minutes. If another package manager still holds the lock when that expires, let it finish, then run `sudo /usr/local/sbin/bootstrap-host` again. A manual retry prints progress in your terminal. Updating the local script does not update an existing guest's copy.

## Teardown

```bash
terraform destroy
```

This removes the instance, its boot volume, the data volume and its contents, and the managed networking resources.
