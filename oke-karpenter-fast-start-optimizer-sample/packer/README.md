<!-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. -->
<!-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ -->

# Packer Pipeline for Optimized OKE Worker Images

This directory contains a Packer pipeline that takes an Oracle-published OKE worker image OCID and creates a custom optimized OKE worker image with the image-based fast-start optimizations used by the Terraform implementation.

The Packer Oracle OCI builder launches a temporary OCI instance from `base_image_ocid`, runs the provisioner script, snapshots the result as a custom image, and terminates the temporary instance. The builder behavior is based on the official HashiCorp Oracle OCI Packer builder.

## What This Pipeline Bakes Into the Image

The provisioner script implements only image-time optimizations:

- Installs `oraclelinux-developer-release-el8`.
- Installs `jq`, `curl`, and `python36-oci-cli`.
- Verifies `crictl` exists on the OKE worker image.
- Starts CRI-O only during the image build.
- Pre-pulls digest-pinned OKE infrastructure images into CRI-O storage.
- Verifies the pre-pulled image layers are present.
- Writes `/var/lib/oke-optimization/image-build-manifest.json`.
- Cleans DNF cache, transient cloud-init state, logs, shell history, and machine identity.
- Preserves `/etc/oke` and CRI-O image storage.

It intentionally does not implement runtime bootstrap changes. Runtime bootstrap still belongs in the KPO `OCINodeClass.spec.metadata.user_data` template.

## Required Inputs

At minimum you must provide:

- `base_image_ocid`: OCID of the Oracle-published OKE worker image to optimize.
- `availability_domain`: AD for the temporary builder instance.
- `subnet_ocid`: subnet that the Packer host can SSH into.
- `compartment_ocid`: compartment for the temporary builder instance.

The example uses placeholder OCIDs. Replace them with values from your tenancy before building.

## Usage

Initialize the Packer plugin:

```sh
cd packer
packer init .
```

Create a local var file:

```sh
cp oke-optimized-worker.example.pkrvars.hcl local.pkrvars.hcl
```

Edit `local.pkrvars.hcl` and set:

```hcl
base_image_ocid     = "REPLACE_WITH_BASE_OKE_WORKER_IMAGE_OCID"
base_image_name     = "Oracle-Linux-8.10-..."
compartment_ocid    = "REPLACE_WITH_COMPARTMENT_OCID"
availability_domain = "..."
subnet_ocid         = "REPLACE_WITH_SUBNET_OCID"
image_name          = "oke-optimized-ol8-oke-1-35-2-fast-start-packer"
ssh_public_key_path = "/absolute/path/to/id_rsa.pub"
ssh_private_key_path = "/absolute/path/to/id_rsa"
```

Validate:

```sh
packer validate -var-file=local.pkrvars.hcl .
```

Build:

```sh
packer build -var-file=local.pkrvars.hcl .
```

Or use the wrapper that takes the base OKE worker image OCID and discovers builder settings from Terraform outputs and OCI CLI:

```sh
./scripts/build-from-image-ocid.sh <base-oke-worker-image-ocid>
```

For a different tenancy or standalone Packer use, provide overrides:

```sh
PACKER_COMPARTMENT_OCID=<compartment-ocid> \
PACKER_SUBNET_OCID=<subnet-ocid> \
PACKER_AVAILABILITY_DOMAIN='xxxx:US-ASHBURN-AD-1' \
PACKER_SSH_PUBLIC_KEY_PATH=/absolute/path/to/id_rsa.pub \
PACKER_SSH_PRIVATE_KEY_PATH=/absolute/path/to/id_rsa \
./scripts/build-from-image-ocid.sh <base-oke-worker-image-ocid>
```

To validate the generated Packer variables without building an image:

```sh
PACKER_VALIDATE_ONLY=true ./scripts/build-from-image-ocid.sh <base-oke-worker-image-ocid>
```

For a script-only test that provisions the builder but does not create an image, set:

```hcl
skip_create_image = true
```

## Example One-Off Build

```sh
packer build \
  -var 'base_image_ocid=<base-oke-worker-image-ocid>' \
  -var 'base_image_name=Oracle-Linux-8.10-2026.02.28-0-OKE-1.35.2-1402' \
  -var 'availability_domain=REPLACE_WITH_AD_NAME' \
  -var 'subnet_ocid=REPLACE_WITH_IMAGE_BUILDER_SUBNET_OCID' \
  -var 'image_name=oke-optimized-ol8-oke-1-35-2-fast-start-packer' \
  .
```

## Drift and Rebuild Guidance

This pipeline freezes packages and pre-pulled image layers at build time. That is what makes node boot faster, but it also means the optimized image must be rebuilt.

Rebuild when:

- Oracle publishes a newer OKE worker image for the target Kubernetes version.
- Any OKE infrastructure image digest changes.
- The Kubernetes target version changes.
- A security cadence requires package refresh, for example monthly.
- Application teams change any app images added to `prepull_images`.

Avoid mutable `latest` tags in `prepull_images`. Use region-correct digest-pinned image references so the image build is deterministic.

Prefer rebuilding from Oracle's latest OKE worker image over running broad, untested `dnf update -y` on an older worker image. OKE worker images are curated artifacts; package-level mutation should be validated with a node-join and workload scheduling test before promotion.

## Promotion Checklist

After Packer creates the image:

1. Confirm the image is `AVAILABLE` in OCI.
2. Confirm tags include `k8s_version`, `base_image_ocid`, `base_image_name`, `optimization_profile`, and `prepull_images_sha256`.
3. Update the KPO `OCINodeClass` image ID to the new custom image OCID.
4. Launch one Karpenter node from the new image.
5. Confirm the node joins Ready.
6. Confirm `/var/lib/oke-optimization/image-build-manifest.json` exists on the node.
7. Run a small workload pinned to `oke-optimization.oracle.com/profile=fast-start`.
8. Run the larger scale test after the smoke test passes.
