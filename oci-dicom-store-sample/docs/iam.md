# IAM prerequisites

The safest operating model is an OCI Resource Manager stack or dedicated
deployment group with access to the target compartment plus the minimum
tenancy-level permissions documented below.

## Compartment resources

The deploying principal needs to manage:

- VCNs, subnets, gateways, route tables, NSGs, and NSG rules
- DRGs, DRG attachments, and FastConnect virtual circuits when enabled
- Compute instances, VNICs, images, and boot volumes for the bastion
- OKE enhanced clusters, managed node pools, and Compute worker nodes
- OCI Network Load Balancers provisioned by the OKE cloud controller
- API Gateway gateways and deployments
- OCI Database with PostgreSQL systems
- Object Storage buckets in the target compartment
- log groups, service logs, Monitoring alarms, and work requests

It also needs read access to tenancy availability domains, region
subscriptions, Object Storage namespace, and service CIDRs. The stack creates
the bucket through OCI's native API directly in `compartment_id`; it does not
change the tenancy-wide S3-compatible API compartment designation.

For an isolated deployment compartment, a tenancy administrator can start with:

```text
Allow group DicomDeployers to manage all-resources in compartment Dicom
Allow group DicomDeployers to read compartments in tenancy
Allow group DicomDeployers to inspect tenancies in tenancy
```

For an existing root-level bucket, the first corrective apply also needs
`BUCKET_UPDATE` and `BUCKET_CREATE` in the source compartment so OCI can move
it to `Dicom`. Narrow the broad first statement to service families after a
successful initial plan in your tenancy.

## Storage identity modes

### Existing OCI IAM user

With `create_storage_customer_secret_key = true`, Terraform looks up exactly
one existing OCI IAM user by `storage_user_email`. It creates a stack-specific
group, membership, Customer Secret Key, and bucket-scoped policy. Terraform
does not create, modify, or delete the selected user. The deployment principal
must be allowed to inspect users and manage the stack-owned IAM resources.
Destroy deletes those four stack-owned access resources but leaves the selected
user and every unrelated credential on that user untouched.

The selected user must have the Customer Secret Key capability enabled and an
available key slot; OCI permits at most two Customer Secret Keys per user.
OCI may return the key as `ACTIVE` before it has propagated to the regional S3
compatibility endpoint. The apply workflow waits for a successful signed,
read-only bucket request before it updates Orthanc, preventing a newly created
credential from reaching the workload prematurely.

The generated runtime policy is bucket-scoped:

```text
Allow group <deployment>-storage to read buckets in compartment id <s3-compartment-ocid> where target.bucket.name = '<bucket>'
Allow group <deployment>-storage to manage objects in compartment id <s3-compartment-ocid> where target.bucket.name = '<bucket>'
```

IAM writes use the `home_region` provider alias because they must target the
tenancy home region. This does not cause the compartment-scoped policy to be
placed in the tenancy root.

Set `create_storage_customer_secret_key = false` to use a pre-existing Access
Key/Secret Key pair. Supply it through `TF_VAR_storage_access_key` and
`TF_VAR_storage_secret_key`; the corresponding user, policy, and credential
lifecycle are then external to this stack. The deployment still performs the
same signed bucket-list readiness request before releasing either credential
mode to Orthanc.

## OKE operator and service identities

Terraform creates a dynamic group whose matching rule contains only the
deployed bastion instance OCID. Its compartment policy grants `CLUSTER_USE`
and `CLUSTER_MANAGE` only for the deployed OKE cluster. `CLUSTER_USE` enables
an instance-principal private kubeconfig without copying an API key to the
host; `CLUSTER_MANAGE` authorizes the bastion through OKE's Kubernetes IAM
authorizer to apply and remove the stack workloads. The latter is required in
addition to kubeconfig creation: authentication alone does not grant
Kubernetes API permissions.

The OKE cluster principal receives compartment-scoped permission to create and
delete its internal Network Load Balancer and use the VCN resources needed by
the cloud controller. These policies are required even when
`create_storage_customer_secret_key = false`.

## OCI IAM Identity Domains SSO

When `oci_identity_domain_sso` is set, the deploying principal also needs
permission to manage applications, groups, and grants in that existing
identity domain. The provider addresses Identity Domains through the domain's
home-region URL; these resources are not compartment-local application
resources even when the domain itself is assigned to a compartment.

The stack creates no SSO users. Existing users are added to the generated role
groups by an identity-domain administrator. See [OCI SSO](sso.md) for the
group-to-Orthanc-role mapping and lifecycle behavior.

### Externally managed Customer Secret Key

For a compartment-scoped deployment:

1. Select an existing user and Customer Secret Key whose secret is still
   available to the deployment operator.
2. Grant that user the two bucket-scoped statements above outside this stack.
3. Set `create_storage_customer_secret_key = false`.
4. Pass `storage_access_key` and `storage_secret_key` as sensitive CI or Resource
   Manager variables.

OCI returns a Customer Secret Key's secret only once. If it is lost, create a
replacement rather than attempting to retrieve it.

## Authentication modes

`oci_auth` supports API key, security token, instance principal, resource
principal, and OKE workload identity modes accepted by the provider. Local
workstations normally use `APIKey` or `SecurityToken`; OCI Resource Manager uses
`ResourcePrincipal`.

Never put key files, session tokens, OCIDs tied to another environment, or
plaintext secrets in committed Terraform files.
