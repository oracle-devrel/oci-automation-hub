# Keycloak configuration

This document describes how this repository creates and maintains the
Keycloak configuration used by Orthanc Explorer, Stone, OHIF, DICOMweb, and
optional OCI IAM Identity Domains single sign-on (SSO).

The supported method is to change Terraform inputs or the declarative realm in
`terraform/locals.tf`, then deploy it. Do not maintain the same objects by hand
in the Keycloak Admin Console: every workload deployment reconciles the realm
back to the Terraform definition and `make verify` reports any drift.

## Authentication and authorization flow

```text
Local user ---------------------------> Keycloak realm "orthanc"
                                             |
OCI IAM user -> OCI Identity Domain -------> | realm roles
                                             v
Orthanc / Stone / OHIF / DICOMweb -> Orthanc authorization service
                                             |
                                             v
                                  permission + tenant-label check
```

Keycloak proves the user's identity and puts realm roles in the access token.
It does not decide whether a DICOM study is visible. The Orthanc authorization
service maps those roles to actions such as `view`, `download`, and `upload`,
and enforces study labels for tenant roles.

## What the stack creates

The desired state is defined in `local.keycloak_realm` in
`terraform/locals.tf`.

### Realm

| Setting | Value |
| --- | --- |
| Realm name | `orthanc` |
| Display name | `Orthanc` |
| TLS requirement | External requests require TLS |
| User registration | Disabled |
| Password reset | Enabled |
| Login with email | Enabled |
| Duplicate email addresses | Disabled |
| Brute-force protection | Enabled |
| Access-token lifetime | 5 minutes |
| SSO idle timeout | 30 minutes |
| SSO maximum lifetime | 10 hours |
| Login/admin events | Enabled; login events retained for 30 days |

### OIDC client

The stack manages one browser client:

| Setting | Value |
| --- | --- |
| Client ID | `orthanc` |
| Client name | `Orthanc Explorer` |
| Client type | Public OpenID Connect client |
| Authorization Code flow | Enabled |
| Direct Access Grants | Enabled for the repository's automated checks and operator scripts |
| Valid redirect URIs | `<public-base-url>/orthanc/*` |
| Web origin | `<public-base-url>` |
| Front-channel logout | Enabled |
| Full scope | Enabled |

An `account audience` protocol mapper adds `account` to the access-token
audience. Orthanc Explorer is configured with the same realm and client ID.
Stone and OHIF are opened with short-lived, study-scoped tokens issued through
the Orthanc authorization integration; they are not separate Keycloak clients
in this deployment.

Do not reuse the `orthanc` browser client for a new confidential application.
An external viewer that performs its own OIDC login should receive a dedicated
client with only its exact redirect URIs. It must also support bearer tokens on
DICOMweb requests. Merely creating a Keycloak client does not grant access to
unlabeled or unauthorized studies.

### Realm roles

The following platform roles can see all tenant labels and should be reserved
for central operations:

| Keycloak role | Orthanc permissions |
| --- | --- |
| `orthanc-viewer` | View and download |
| `orthanc-uploader` | View, download, and upload |
| `orthanc-editor` | View, download, upload, modify, anonymize, delete, edit labels, send, and share |
| `orthanc-admin` | Full platform administration, including settings, worklists, audit logs, remote modalities, and label classification |

For each entry in `orthanc_tenants`, Terraform also creates:

```text
tenant-<tenant-key>-viewer
tenant-<tenant-key>-uploader
tenant-<tenant-key>-editor
tenant-<tenant-key>-admin
```

These roles are restricted to the configured tenant label. A newly uploaded
study remains invisible to tenant users until a trusted `orthanc-admin`
assigns exactly one tenant label.

### Managed users

The stack creates a local break-glass user named by `orthanc_username`, which
defaults to `orthanc-admin`, and assigns it the `orthanc-admin` realm role. Its
password is generated unless `orthanc_password` is supplied.

When `enable_tenant_test_users = true`, the stack also creates one synthetic
editor per tenant for acceptance tests. Keep this disabled outside the test
window.

The master-realm bootstrap administrator is `keycloak-admin`. It is for
Keycloak administration only; do not use it as an Orthanc user.

## Create the configuration

### 1. Configure Terraform inputs

Copy the example file if the deployment does not already have one:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

At minimum, configure the normal OCI deployment inputs and define the approved
tenant catalog:

```hcl
keycloak_replicas = 2

orthanc_tenants = {
  hospital-a = { display_name = "Hospital A" }
  hospital-b = { display_name = "Hospital B" }
}

enable_tenant_test_users = false
```

Leave `keycloak_admin_password` and `orthanc_password` unset to let Terraform
generate strong values. If they must be supplied externally, pass them as
sensitive variables, for example `TF_VAR_keycloak_admin_password` and
`TF_VAR_orthanc_password`; do not commit them to `terraform.tfvars`.

To enable OCI IAM SSO, add the identity domain that owns the workforce users:

```hcl
oci_identity_domain_sso = {
  identity_domain_id = "ocid1.domain.oc1..replace_me"
  group_names = {
    orthanc-viewer   = "Orthanc-Viewers"
    orthanc-uploader = "Orthanc-Uploaders"
    orthanc-editor   = "Orthanc-Editors"
    orthanc-admin    = "Orthanc-Administrators"
  }
}
```

All four platform group keys are required. Terraform prefixes the display
names with the deployment name and also generates four groups per tenant. The
resulting names are unique to this stack.

### 2. Validate and deploy

Run the supported workflow from the repository root:

```bash
make validate
make plan
make show-plan
make apply
```

During the deployment, automation:

1. Creates a dedicated PostgreSQL role and schema for Keycloak.
2. Stores runtime credentials and the generated realm import as Kubernetes
   Secrets.
3. Starts at least two Keycloak replicas with the realm import.
4. Reconciles realm settings, roles, the `orthanc` client, managed users, the
   OCI identity provider, and all OCI role mappers through the Admin API.
5. Rolls out the Orthanc authorization service with the corresponding role and
   tenant-label permissions.

Realm import creates the realm on first startup. Import alone does not update
an existing realm, which is why `scripts/reconcile-keycloak-oci-mappers.sh`
runs after every workload deployment.

### 3. Retrieve URLs and credentials

```bash
make get-credentials
```

This prints the Orthanc login, the Keycloak Admin Console URL, generated
break-glass credentials, OCI group names, and tenant mappings. Treat this
output as sensitive and do not paste it into tickets or logs.

The important endpoint shapes are:

```text
Admin Console:
  https://<api-gateway-host>/keycloak/admin/

Realm OIDC discovery:
  https://<api-gateway-host>/keycloak/realms/orthanc/.well-known/openid-configuration

Orthanc login:
  https://<api-gateway-host>/orthanc/ui/app/
```

The API Gateway permits only `allowed_client_cidrs`. If the operator's public
IP changes, update that input and apply before testing these URLs.

### 4. Assign workforce access

When OCI IAM SSO is enabled, Terraform creates the Identity Domains
application, its grants, the custom group-name claim, the Keycloak broker, and
the role mappers. It does not create or modify workforce users.

In the OCI Console, open **Identity & Security > Domains**, select the configured
domain, and add each existing user to the minimum generated group required for
their job. Prefer a tenant group over a platform-wide group. Use the exact
group names printed by `make get-credentials`.

Group membership is mapped at the next brokered login. After changing a
membership, sign out of Orthanc and sign in again with **OCI IAM SSO**, or
revoke the existing Keycloak session when the change must take effect
immediately. See [OCI IAM Identity Domains SSO](sso.md) for the complete group
mapping and lifecycle.

### 5. Verify

```bash
make verify
```

Verification checks:

- local OIDC token issuance;
- OCI discovery metadata and the SSO authorization redirect when enabled;
- the custom OCI group claim;
- the complete Terraform-to-Keycloak reconciliation state;
- authenticated Orthanc REST and DICOMweb access;
- Stone and OHIF endpoints.

For tenant-isolation acceptance testing, temporarily enable the synthetic
tenant users, apply, run `make verify-compliance`, then disable the users and
apply again.

## Manual Admin Console reference

The console is useful for inspection and emergency diagnosis. The expected
objects are under the `orthanc` realm:

1. **Realm settings** contains the security, token, session, and event values
   listed above.
2. **Realm roles** contains the four `orthanc-*` roles and four roles for every
   configured tenant.
3. **Clients > orthanc** contains the public OIDC client and exact API Gateway
   redirect/origin values.
4. **Users** contains the local break-glass account and only the enabled
   synthetic test users.
5. **Identity providers > oci**, when enabled, contains the OCI authorization,
   token, user-info, logout, issuer, and JWKS endpoints. Signature validation,
   JWKS, PKCE S256, and forced synchronization are enabled.
6. **Identity providers > oci > Mappers** contains one Claim-to-Role mapper for
   each platform and tenant role. Each mapper matches the stack-specific OCI
   group-name claim to one Keycloak realm role.

If an emergency manual edit is required, record it and immediately reproduce
it in Terraform. Otherwise the next `make deploy-oke` will restore the
declarative values. Never copy the OCI client secret, user passwords, or the
sensitive `keycloak_reconciliation` Terraform output into documentation.

## Change an existing configuration

Use these source-of-truth locations:

| Change | File or input |
| --- | --- |
| Realm security/session values | `local.keycloak_realm` in `terraform/locals.tf` |
| Orthanc OIDC client | `local.keycloak_realm.clients` in `terraform/locals.tf` |
| Platform role permissions | `local.orthanc_role_permissions` in `terraform/locals.tf` |
| Tenant names and labels | `orthanc_tenants` input |
| OCI domain and platform group labels | `oci_identity_domain_sso` input |
| Keycloak image | `keycloak_image` input |
| Replica count | `keycloak_replicas` input |

After a change, run `make validate`, review `make plan`, deploy with
`make apply` or `make deploy-oke` as appropriate, and finish with
`make verify`.

## Troubleshooting

`Keycloak user <name> does not match Terraform` means a managed user differs
from the declared state. Do not delete the database or realm. Run the normal
workload deployment to reconcile it, then verify again.

`Keycloak OCI identity provider does not match Terraform` means the broker or
one of its non-secret settings differs. Confirm the identity-domain input and
OCI application still exist, then run `make deploy-oke`. Keycloak masks stored
client secrets in Admin API responses; the reconciliation check accounts for
that behavior.

An SSO login loop or OCI `redirect_uri` error normally means the broker
callback does not exactly match:

```text
https://<api-gateway-host>/keycloak/realms/orthanc/broker/oci/endpoint
```

A valid login followed by HTTP 403 normally means the token has no recognized
Orthanc/tenant role, or the requested study does not have a permitted tenant
label. Check OCI group membership, sign in again to refresh the token, and
check the study classification.

If the Admin Console or login URL times out, first confirm the current public
IP is included in `allowed_client_cidrs`; this is independent of Keycloak
realm configuration.

## Secret and state handling

Keycloak database credentials, the bootstrap administrator password, the
break-glass password, and the OCI broker client secret are present in
Terraform state. Use encrypted remote state with tightly restricted operator
access. Runtime values are mounted from Kubernetes Secrets, not ConfigMaps.
Do not commit rendered manifests, exported realms, access tokens, passwords,
or Terraform state files.
