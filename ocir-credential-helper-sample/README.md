<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# OCI OCIR Credential Helper Automation

## Overview

This Terraform stack deploys an Oracle Cloud Infrastructure (OCI) environment that demonstrates passwordless access to Oracle Container Registry (OCIR) using:
- OCI Instance Principals
- Docker credential helpers
- OCI IAM policies

The automation creates a VM configured to pull private OCIR images without running `docker login` or storing credentials.

Authentication is performed dynamically using OCI IAM and the instance identity.

### Architecture

After deployment, image pulls follow this authentication flow:

```
docker pull fra.ocir.io/<namespace>/<repo>:tag
        │
        ▼
Docker calls docker-credential-ocir
        │
        ▼
OCI CLI requests OCIR auth token
        │
        ▼
Instance Principal (via OCI metadata service)
        │
        ▼
OCI IAM returns temporary OCIR credentials
```
No credentials or tokens are stored on the VM.

### What This Automation Deploys

The Terraform stack creates the following OCI resources.

**Network**
- VCN, Public subnet, Private subnet, Internet Gateway, NAT Gateway, Route tables, Security lists

**Compute**
- Oracle Linux 9 VM

**Credential Helper**
The instance builds and installs the OCIR Docker credential helper: `docker-credential-ocir`.
Docker is configured to use this helper automatically when pulling from OCIR.

---

## Getting Started

### Prerequisites

- OCI account
- Terraform installed
- SSH key pair
- IAM Dynamic Group configured for the instance. Documentation - [Managing Dynamic Groups](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm)
  
Example IAM policy:
```
allow dynamic-group <dynamic-group-name> to read repos in tenancy
OR
allow dynamic-group <dynamic-group-name> to manage repos in tenancy
```

---

### Configuration

1. Configure Provider

    Rename: 

        `provider.auto.tfvars.tpl → provider.auto.tfvars`

    Edit the file and provide:
    - tenancy OCID
    - user OCID
    - fingerprint
    - private key path
    - region
    - compartment_ids

2. Configure Terraform Variables
   
    Review `terraform.tfvars`. 

    Example registry configuration:

    `registry = "fra.ocir.io"`

    Supported examples:

        ```
        fra.ocir.io
        iad.ocir.io
        phx.ocir.io
        ```

---

### Run Terraform

        ```
        terraform init
        terraform plan
        terraform apply
        ```

**Note:**  
Infrastructure creation typically takes 2–3 minutes.
The instance configuration continues via cloud-init.

---

### Verify Deployment

After Terraform completes wait a few more minutes (or you can monitor the `/var/log/clound-init-output.log` to observe when the script completes), then retrieve the instance IP from the output and SSH to the instance:

`ssh opc@<instance_public_ip>`

Verify Docker:

`docker version`

Verify Credential Helper

`which docker-credential-ocir`

Expected output:

`/usr/local/bin/docker-credential-ocir`

Verify Instance Principal

`oci iam region list --auth instance_principal`

If IAM is configured correctly, the command returns the list of OCI regions.

---

### Test OCIR Image Pull

Example:
`docker pull fra.ocir.io/<namespace>/<repo>:<tag>`

Docker automatically authenticates using the credential helper and instance principal.
No manual login is required.

---

### Test OCIR Image Push

The instance can also push images to Oracle Container Registry (OCIR) using the same credential helper and instance principal authentication.

**Important**

To push images, the dynamic group must have manage permissions on OCIR repositories.

1. Tag an image for OCIR:

Example:

`docker tag alpine:latest fra.ocir.io/<namespace>/<repo>:v1`

Verify:

`docker images`

2. Push the image:

`docker push fra.ocir.io/<namespace>/<repo>:v1`

Docker automatically authenticates using the OCIR credential helper and instance principal.
No manual login is required.

---

### Cloud-init logs

If you SSH into the VM immediately after creation, make sure to reconnect once provisioning completes. The `opc` user is added to the `docker` group by the cloud-init script, and sessions started before that step will not have the updated group membership, causing Docker commands to fail. You can monitor provisioning progress by tailing the cloud-init logs. The full setup typically completes within about 5 minutes.
If troubleshooting is required:

`sudo tail -f /var/log/cloud-init-output.log`

or

`sudo tail -f /var/log/cloud-init.log`

---

## Cleanup

When finished, destroy the environment:

```
terraform destroy
```

---

## Notes

- This stack is intended for demonstration and automation examples.
- Security lists allow broad ingress/egress for simplicity.
- Instance Principal authentication requires proper IAM policies and dynamic group configuration.
- The credential helper is compiled during instance provisioning.

---