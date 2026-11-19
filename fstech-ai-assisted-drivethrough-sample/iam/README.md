<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# IAM setup for the FSTech Drive-Thru stack

IAM is configured in two layers.

## Zero-manual-IAM deployment

For a new tenancy, create and apply the Resource Manager stack while signed in
as a member of the tenancy `Administrators` group. No IAM policy needs to be
copied or created manually. Terraform creates the application instance dynamic
group and all runtime policies in `iam.tf`.

The stack discovers the tenancy home region from OCI region subscriptions and
uses it for the aliased `oci.home` provider. Application resources continue to
use the Resource Manager deployment region, so there is no home-region input
or region-key mapping to maintain.

The administrator authorization is only the credential used to start
Terraform. It cannot be created by the same Terraform run because OCI must
authorize the caller before Terraform is allowed to create its first resource.

## Optional non-administrator deployment setup

If the person deploying the stack is not a tenancy administrator, that identity
must already be authorized to create the application resources. This is an OCI
authentication prerequisite rather than an application runtime policy.

As an OCI tenancy administrator:

1. Create an identity-domain group named `FSTechDeployers`.
2. Add the user who will create and apply the Resource Manager stack.
3. In the tenancy root compartment, create a policy named
   `FSTechDriveThruDeploymentPolicy`.
4. Copy the statements from `deployer-policy.template.txt`.
5. Replace `<APP_COMPARTMENT_OCID>` with the target compartment OCID.

The supplied template uses a group in the Default identity domain with the
short subject `group FSTechDeployers`. If the group is in another identity
domain, replace that subject on every line with:

```text
group '<IDENTITY_DOMAIN_NAME>'/'FSTechDeployers'
```

The two tenancy-level `manage` statements are necessary because the main stack
creates an instance dynamic group and its runtime policy in the root
compartment. If your security team does not allow deployers to manage IAM,
have an administrator run the stack. This is the recommended end-to-end path.

`inspect all-resources` provides read-only discovery for Terraform plan and OCI
Console selectors. The remaining resource families are scoped to the target
parent compartment and inherited by its Network, Data, AI, and Application
children. The deployer also needs `manage compartments` in the selected parent
so Terraform can create that layout.

## Application runtime permissions (always Terraform-managed)

During apply, `iam.tf` creates:

- A dynamic group matching only the application compute instance OCID.
- A root-compartment policy allowing that instance to chat with the GenAI
  Agent endpoint, create sessions, synchronize function tools, analyze plate
  images, run Speech STT/TTS, and use the application Object Storage bucket.

No API key or OCI configuration file is stored on the VM. The application uses
instance-principal authentication.

The runtime policy template is provided for review or manual recovery. Normally
you should not create it manually because Terraform creates and owns it.

## Resource Manager stack access

The deployer policy permits Resource Manager plan and apply jobs. Anyone with
`read orm-jobs` can potentially read Terraform state and configuration, which
contain generated database credentials. Keep membership in `FSTechDeployers`
restricted and remove users who no longer deploy this application.
