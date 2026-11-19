# OCI IAM Identity Domains SSO

The stack can federate Orthanc with the OCI IAM identity domain that already
contains workforce accounts. Terraform does not create or replace users. It
creates one confidential OIDC application, four privileged platform role
groups, four groups per configured tenant, app grants for those groups, and a
Keycloak broker configuration.

The browser authentication flow is:

```text
Orthanc Explorer -> Keycloak -> OCI IAM Identity Domain -> Keycloak -> Orthanc Explorer -> Stone/OHIF
```

Keycloak remains between Orthanc and OCI IAM because Orthanc Explorer and the
official Orthanc authorization service integrate with Keycloak roles. OCI IAM
performs authentication and MFA; Keycloak maps the OCI group claim into the
Orthanc authorization roles. Stone and OHIF are launched from Orthanc Explorer
with short-lived, study-scoped viewer tokens, so both viewers inherit the same
role and tenant-label decisions.

## Enable SSO

Find the identity domain that owns the existing users under **Identity &
Security > Domains**. Set its domain OCID in `terraform/terraform.tfvars`:

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

Then run the normal deployment:

```bash
make plan
make apply
make verify
make get-credentials
```

Terraform registers the exact Keycloak callback URL in OCI IAM and configures
the authorization-code flow with PKCE. It also creates an application-specific
OAuth scope and custom identity-token claim that flattens OCI group objects to
group-name strings. This is required because OCI's built-in `get_groups` claim
is an array of objects, while Keycloak's stock Claim-to-Role mapper matches an
array of strings. Keycloak validates the returned token signature and issuer
against the identity-domain endpoints.

## Give an existing user access

After the apply, open the selected identity domain in the OCI Console and add
the existing user to exactly the groups required for their job. The groups are
shown by `make get-credentials` and `terraform -chdir=terraform output oci_sso`.

| OCI IAM group | Orthanc role | Effective access |
| --- | --- | --- |
| `<deployment> - Orthanc-Viewers` | `orthanc-viewer` | View and download |
| `<deployment> - Orthanc-Uploaders` | `orthanc-uploader` | View, download, and upload |
| `<deployment> - Orthanc-Editors` | `orthanc-editor` | Clinical content editing and deletion |
| `<deployment> - Orthanc-Administrators` | `orthanc-admin` | Full Orthanc administration |

Those four roles are platform-wide and therefore cross tenant boundaries. Use
them only for approved central operations. Normal workforce access uses the
generated tenant groups, for example:

| Generated OCI IAM group | Keycloak role | Effective access |
| --- | --- | --- |
| `<deployment> - Hospital A - Orthanc Viewers` | `tenant-hospital-a-viewer` | View/download studies labeled `tenant-hospital-a` |
| `<deployment> - Hospital A - Orthanc Uploaders` | `tenant-hospital-a-uploader` | Upload plus view/download that tenant's labeled studies |
| `<deployment> - Hospital A - Orthanc Editors` | `tenant-hospital-a-editor` | Tenant-scoped clinical operations and deletion |
| `<deployment> - Hospital A - Orthanc Admins` | `tenant-hospital-a-admin` | Tenant-scoped operations and audit viewing; no study classification |

Custom group labels are supported through the `group_names` map. Terraform
prefixes every display name with the unique deployment name so another stack
or an unrelated identity-domain group cannot satisfy the same claim value. All four keys
must be present because they are the stable authorization contract consumed by
the Orthanc authorization service. Display names are trimmed and must be
globally unique, case-insensitively, across platform and tenant groups; the
plan fails before OCI can create an ambiguous claim mapping.

Tenant group names are derived from `orthanc_tenants`; use
`make get-credentials` or the `tenant_authorization` output for the exact map.
Assign each person to one tenant role whenever possible. Membership in two
tenant groups intentionally grants access to both label sets. Only the global
`orthanc-admin` performs trusted study classification.

Open the Orthanc Web UI and select **OCI IAM SSO**. After login, an authorized
study can be opened in either Stone or OHIF. A user not assigned to one of the
application groups cannot use the OCI application. A user assigned to the
application but to no mapped role cannot access Orthanc resources or either
viewer's DICOMweb data.

Group changes take effect on the next brokered login, not in an already-issued
Keycloak session. After adding or removing a user, sign out of Orthanc and sign
in again with **OCI IAM SSO**. Administrators can also revoke that user's
Keycloak sessions when access must change immediately.

The generated local `orthanc-admin` Keycloak account remains available as a
break-glass account. Store that password securely and use OCI SSO for normal
interactive access.

## Lifecycle and security

- The OCI client secret is sensitive Terraform state and is mounted into
  Keycloak through a Kubernetes Secret, not a ConfigMap.
- Identity-domain writes happen through the home-region OCI provider.
- Every workload deploy reconciles the existing Keycloak realm, roles, client,
  stack-managed users, broker, and mappers. `make verify` checks that complete
  desired state as well as OCI discovery metadata, the custom claim, and the
  authorization request sent to OCI.
- Destroy removes the stack-created confidential application, grants, and role
  groups as well as the custom claim. It does not delete existing OCI IAM
  users. Memberships in those stack-created groups disappear with the groups.
- Setting `oci_identity_domain_sso = null` removes the broker and its managed
  mappers on the next `make deploy-oke`; no database rebuild is required. The
  local Keycloak account remains usable.

OCI documents confidential application registration and authorization-code
flows in [Adding a Confidential Application](https://docs.oracle.com/en-us/iaas/Content/Identity/applications/add-confidential-application.htm)
and [OCI IAM OAuth and OpenID Connect best practices](https://docs.oracle.com/en-us/iaas/Content/Resources/Assets/whitepapers/oci-iam-oauth-flows-best-practices.pdf).
