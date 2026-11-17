# Large DICOM uploads through an HTTPS NLB

The optional large-upload endpoint bypasses OCI API Gateway's 20 MB request-body
limit. Clients connect to a separate public Network Load Balancer on port 443;
TLS terminates on the existing NGINX gateway pods, which stream requests to
Orthanc. The API Gateway URL remains the UI and Keycloak login endpoint.

## Enable

Set `enable_large_upload_endpoint = true` in `terraform/terraform.tfvars`, then
run `make plan`, review the plan, and run
`make apply PRIVATE_KEY="$HOME/.ssh/id_ed25519"`.

The NLB accepts only `allowed_client_cidrs`. It exposes DICOMweb under
`/orthanc/dicom-web/` and REST upload at `/orthanc/instances`. UI, Keycloak,
and administrative routes are excluded. Orthanc continues to validate bearer
tokens and enforce the existing roles, quarantine rules, and tenant labels.
NGINX disables request buffering and its body-size limit; this removes the
gateway's 20 MB cap, but capacity and timeouts still depend on the workload.
NGINX upload/read/write inactivity timeouts are 1,200 seconds. Benchmark your
largest objects and concurrent uploads before selecting production limits.

## Configure client trust

Terraform reserves a stable public IP and generates a server certificate whose
IP subject alternative name matches it. Export the **public** certificate:

```bash
terraform -chdir=terraform output -raw large_upload_certificate > large-upload-ca.pem
terraform -chdir=terraform output -raw large_upload_endpoint
terraform -chdir=terraform output -raw large_upload_dicomweb_endpoint
```

Distribute this certificate through a trusted channel and use it as an explicit
trust anchor. Do not use `curl -k` or disable certificate validation. Private-key
material is stored in Terraform state and a Kubernetes Secret; protect state
with appropriate access controls and encryption. The certificate has a one-year
lifetime and renews on apply within its final 30 days. Redistribute the new
certificate when renewing; the deployment does not automate client trust updates.

## Upload

Obtain a short-lived bearer token from the existing Keycloak endpoint using an
account authorized to upload. Store it in `ACCESS_TOKEN` without logging it.
For Orthanc REST upload, send the DICOM file as the request body:

```bash
UPLOAD_ROOT="$(terraform -chdir=terraform output -raw large_upload_endpoint)"
curl --fail-with-body --cacert large-upload-ca.pem \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'Content-Type: application/dicom' \
  --data-binary @synthetic-large.dcm \
  "${UPLOAD_ROOT}/instances"
```

For STOW-RS, configure the DICOMweb client with `large_upload_dicomweb_endpoint`.
It posts a standards-compliant `multipart/related` request to `/studies` below
that root. This is different from curl's `-F` multipart/form-data encoding.
QIDO-RS and WADO-RS can use this same DICOMweb root. Some absolute links emitted
by Orthanc may retain its configured API Gateway public root; configure the
upload client's base URL explicitly. Browser clients needing a separate origin
also need an explicit CORS design; this endpoint targets API clients.

## Verify

For an interactive upload without Terraform credentials on the client, use
`scripts/upload-dicom.py`. Place `generate-test-dicom.py` beside it and pass a
configuration file with the upload URL, existing API and Keycloak URLs, username,
and certificate filename:

```json
{
  "upload_endpoint": "https://YOUR_NLB_IP/orthanc",
  "api_endpoint": "https://YOUR_API_GATEWAY/orthanc",
  "token_url": "https://YOUR_API_GATEWAY/keycloak/realms/orthanc/protocol/openid-connect/token",
  "username": "orthanc-admin",
  "certificate": "large-upload-ca.pem"
}
```

The certificate path is relative to the configuration file. The script prompts
for a password without displaying it. Run with Python 3.10+ and curl:

```bash
python3 scripts/upload-dicom.py --config upload-config.json --synthetic
python3 scripts/upload-dicom.py --config upload-config.json /path/to/test.dcm
```

`--synthetic` generates a 32 MiB image. It remains in Orthanc for viewing unless
you add `--delete-after-upload`. This initial walkthrough uses the administrator;
tenant-restricted images require trusted classification before they are visible.

Run from a network in `allowed_client_cidrs`:

```bash
python3 scripts/verify-large-upload.py
make verify
```

The verifier uploads a synthetic 32 MiB image through STOW-RS, searches for it,
compares the retrieved WADO bytes, and checks anonymous and invalid-token denial.
When two synthetic tenant users are enabled, it also checks quarantine and
cross-tenant isolation. It deletes the test study afterward; Object Storage
versions may remain according to the bucket's versioning policy.

## Disable or destroy

Before disabling the variable, delete the Kubernetes `dicom-large-upload`
Service from the deployed namespace through the bastion and wait for its NLB
to be deleted. Then set the variable to false and apply, removing the reserved
IP, certificate, NSG, and listener. Kubernetes apply does not prune omitted
objects automatically. Remove the unused `large-upload-tls` Secret afterward.

Full `make destroy` also discovers and deletes the Kubernetes-managed public
NLB by its exact reserved address after stopping OKE, before releasing the IP.
The existing data-retention rules for the image bucket still apply.

References: [API Gateway limits](https://docs.oracle.com/en-us/iaas/Content/APIGateway/Reference/apigatewaylimits.htm)
and [OKE NLB configuration](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengconfiguringloadbalancersnetworkloadbalancers-subtopic.htm).
