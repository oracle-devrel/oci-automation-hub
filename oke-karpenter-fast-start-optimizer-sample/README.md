<!-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. -->
<!-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ -->

# OKE Karpenter Fast-Start Workers

Reference implementation for improving Oracle Kubernetes Engine (OKE) scale-out consistency with Oracle's Karpenter Provider for OCI (KPO), optimized Oracle Linux OKE worker images, and Terraform-managed OCI infrastructure.

This project is intended for engineering validation, demos, and as a starting point for production hardening. It is not a replacement for normal OKE upgrade, security, and image promotion processes.

## Problem

Kubernetes burst scaling can be slowed by work that happens repeatedly on every new node:

- package downloads during node boot,
- image pulls for core Kubernetes/OKE components,
- repeated instance metadata lookups,
- bootstrap logic that rediscover values already available in metadata,
- slow or inconsistent scale-down behavior during demos.

When many nodes start at once, these delays stack across the cluster and make scale-out timing harder to predict.

## What This Project Builds

- An OKE enhanced cluster in OCI.
- A small managed OKE node pool used only for the KPO controller.
- KPO installed by Helm.
- IAM policies and a dynamic group for KPO operation and self-managed node `CLUSTER_JOIN`.
- A custom Oracle Linux OKE worker image with image-time optimizations.
- A Karpenter `OCINodeClass` and `NodePool` that launch optimized workers from zero.
- An optimized runtime bootstrap script that calls `/etc/oke/oke-install.sh` with explicit values.
- A Packer pipeline for building the optimized worker image from a base OKE worker image OCID.
- Example workloads for scale testing.

## Optimization Pattern

The implementation intentionally splits work into two phases.

Image build time:

- Start from an Oracle-published OKE worker image for the exact Kubernetes version.
- Install required packages such as `oraclelinux-developer-release-el8`, `jq`, `curl`, and `python36-oci-cli`.
- Start CRI-O only during image build.
- Pre-pull digest-pinned OKE infrastructure images into CRI-O storage.
- Verify the expected image layers are present.
- Clean transient package, cloud-init, log, history, and machine identity state.
- Preserve `/etc/oke` and CRI-O image storage.

Node boot time:

- Fetch instance metadata once.
- Extract API server, cluster CA, and DNS locally with `jq`.
- Call `/etc/oke/oke-install.sh` directly with explicit bootstrap values.
- Pass kubelet reservation and eviction arguments.
- Let OKE manage CRI-O startup order.
- Record timing markers for later boot analysis.

## Repository Layout

```text
.
├── *.tf                                      # Terraform OCI, OKE, IAM, KPO, and Karpenter resources
├── templates/
│   ├── image-builder-cloud-init.sh.tftpl    # Terraform image-builder cloud-init path
│   └── karpenter-optimized-user-data.sh.tftpl
├── packer/
│   ├── oke-optimized-worker.pkr.hcl         # OCI Packer builder
│   ├── oke-optimized-worker.example.pkrvars.hcl
│   ├── scripts/
│   │   ├── build-from-image-ocid.sh
│   │   └── optimize-oke-worker.sh
│   └── README.md
├── terraform.tfvars.example
├── OKE_OPTIMIZED_WORKER_IMAGE_GUIDE.md
├── inflate-100-replicas-deployment.yaml
└── pause-50-replicas-deployment.yaml
```

## Prerequisites

- OCI tenancy and compartment for the project.
- OCI CLI configured with a profile that can manage OKE, compute, networking, IAM policies, and images.
- Terraform.
- Packer, if using the Packer image build path.
- `kubectl`.
- `helm`.
- SSH key pair for the temporary image-builder VM and worker access.
- Network path that allows the local machine or CI runner to SSH into the temporary image-builder instance.

## Terraform Quick Start

Copy the example variables:

```sh
cp terraform.tfvars.example terraform.tfvars
```

Update at minimum:

```hcl
tenancy_ocid             = "REPLACE_WITH_TENANCY_OCID"
parent_compartment_ocid  = "REPLACE_WITH_PARENT_COMPARTMENT_OCID"
project_compartment_ocid = "REPLACE_WITH_PROJECT_COMPARTMENT_OCID"
oke_image_compartment_ocid = "REPLACE_WITH_ORACLE_OKE_IMAGE_COMPARTMENT_OCID"
ssh_public_key_path      = "~/.ssh/id_rsa.pub"
ssh_private_key_path     = "~/.ssh/id_rsa"
image_builder_ssh_cidr   = "203.0.113.10/32"
allowed_kubernetes_api_cidrs = ["203.0.113.10/32"]
```

Then run:

```sh
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

## Packer Image Build

The Packer pipeline can build an optimized image from a base OKE worker image OCID:

```sh
cd packer
packer init .
./scripts/build-from-image-ocid.sh <base-oke-worker-image-ocid>
```

To validate without creating an image:

```sh
PACKER_VALIDATE_ONLY=true ./scripts/build-from-image-ocid.sh <base-oke-worker-image-ocid>
```

For fully portable use, copy and edit:

```sh
cp oke-optimized-worker.example.pkrvars.hcl local.pkrvars.hcl
packer build -var-file=local.pkrvars.hcl .
```

## Karpenter Scale Test

The test workloads are pinned to Karpenter optimized nodes with:

```yaml
nodeSelector:
  oke-optimization.oracle.com/profile: fast-start
tolerations:
- key: oke-optimization.oracle.com/scaling-test
  operator: Equal
  value: "true"
  effect: NoSchedule
```

This prevents test pods from landing on the regular managed OKE node pool.

Apply a test workload manually:

```sh
kubectl apply -f inflate-100-replicas-deployment.yaml
```

Watch scale-out:

```sh
kubectl get nodeclaims
kubectl get nodes -l karpenter.sh/nodepool=optimized-ol8
kubectl get pods -o wide
kubectl logs -n karpenter deploy/karpenter
```

## Cleanup

Delete any sample workloads before destroying the infrastructure:

```sh
kubectl delete -f inflate-100-replicas-deployment.yaml --ignore-not-found
kubectl delete -f pause-50-replicas-deployment.yaml --ignore-not-found
```

Destroy the Terraform-managed resources:

```sh
terraform destroy
```

If you built additional custom worker images with the standalone Packer flow, delete those images from OCI after they are no longer needed. Terraform only destroys images it created through the Terraform image-builder workflow.

## Operational Guidance

Treat optimized worker images as versioned artifacts.

Rebuild when:

- Oracle publishes a newer OKE worker image for the target Kubernetes version.
- Kubernetes version changes.
- CRI-O, VCN CNI, kube-proxy, or other pre-pulled image digests change.
- Security cadence requires package refresh.
- Application teams add or change application images in the pre-pull list.

Avoid mutable tags such as `latest` in pre-pulled images. Prefer region-correct digest-pinned references.

## Important Caveats

- Do not run runtime `systemctl start crio` before OKE bootstrap. Testing showed that runtime CRI-O manipulation can race with OKE service ordering.
- Do not rely on a single optimized image indefinitely. Baked packages and CRI-O image layers become stale over time.
- Do not publish Terraform state, plans, private variables, or SSH keys.
- Restrict `allowed_kubernetes_api_cidrs` and `image_builder_ssh_cidr` before using outside a short-lived test environment.
- Validate every promoted image with node join, CNI, kube-proxy, DaemonSet readiness, and workload scheduling tests.

## Documentation

See [OKE_OPTIMIZED_WORKER_IMAGE_GUIDE.md](./OKE_OPTIMIZED_WORKER_IMAGE_GUIDE.md) for the full implementation guide, rationale, and boot-speed findings.
