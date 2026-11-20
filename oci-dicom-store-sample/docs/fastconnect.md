# FastConnect private ingest

FastConnect is optional. It provides a private path from an on-premises network
to the stack's private OKE Network Load Balancer, avoiding OCI API Gateway's fixed 20 MB
request-size limit. FastConnect does not increase that API Gateway limit.

Terraform automates the OCI side:

- a Dynamic Routing Gateway (DRG)
- a VCN attachment and routes for the declared on-premises CIDRs
- private NLB and bastion NSG access from those CIDRs
- one private FastConnect partner virtual circuit
- a TLS listener on port 8443 for encrypted Orthanc and DICOMweb traffic

The provider order, physical connectivity, provider activation/service key, and
on-premises BGP configuration are external prerequisites. Oracle documents the
same division of responsibility in
[FastConnect with an Oracle Partner](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/fastconnectprovider.htm).

## Provider discovery and inputs

List provider offerings in the workload region, using the tenancy/root
compartment OCID:

```bash
oci network fast-connect-provider-service list \
  --compartment-id "$TF_VAR_tenancy_id" \
  --all \
  --query 'data[].{provider:"provider-name",service:"provider-service-name",id:id,type:type}' \
  --output table
```

Configure:

```hcl
enable_fastconnect              = true
fastconnect_on_premises_cidrs   = ["10.80.0.0/16"]
fastconnect_provider_service_id = "ocid1.providerservice.oc1.eu-frankfurt-1..."
fastconnect_bandwidth_shape_name = "1 Gbps"
fastconnect_customer_asn         = "64512"
fastconnect_is_bfd_enabled       = true
```

Supply the provider key through a protected variable rather than committing it:

```bash
export TF_VAR_fastconnect_provider_service_key_name='provider-activation-key'
```

Some Layer-3 partners manage the bandwidth and BGP ASN. Leave the corresponding
values null when the provider's offering does so. `MTU_1500` is the conservative
default; use `MTU_9000` only when the provider and the complete on-premises path
support it.

## Activation sequence

1. Order and provision the partner connection.
2. Obtain the provider service OCID and service/activation key.
3. Configure the variables and run `scripts/deploy.sh`.
4. Give the generated virtual-circuit information to the provider.
5. Configure the on-premises edge to advertise only the CIDRs declared in
   `fastconnect_on_premises_cidrs`.
6. Confirm provider state is `ACTIVE`, lifecycle state is `PROVISIONED`, and
   IPv4 BGP state is `UP`:

   ```bash
   scripts/verify-fastconnect.sh --control-plane-only
   ```

7. Run the data-plane verifier from an on-premises host whose route traverses
   FastConnect:

   ```bash
   scripts/verify-fastconnect.sh
   ```

The circuit can be created successfully by Terraform while it is still pending
provider action. Do not report it operational until BGP is up and the
data-plane check succeeds.

## TLS trust

FastConnect is private connectivity, but the circuit itself is not application
encryption. The stack therefore creates a self-signed server certificate with
the reserved private NLB address as an IP subject alternative name.

Export the public trust certificate when configuring a client manually:

```bash
terraform -chdir=terraform output -raw fastconnect_private_ingest_certificate \
  > private-ingest-ca.pem
terraform -chdir=terraform output -raw fastconnect_private_ingest_endpoint
```

The private key remains in encrypted Terraform state and a Kubernetes TLS
Secret. The certificate renews during a Terraform apply
within 30 days of its one-year expiration; redistribute the new public
certificate before switching clients. Organizations with an internal PKI can
replace the generated certificate resources with their approved certificate
workflow.

## Availability and fallback

The generic stack creates one partner virtual circuit because provider service
keys and circuit orders are provider-specific. Production medical workloads
should order redundant connectivity and use a second virtual circuit or a
route-based Site-to-Site VPN backup. Oracle recommends redundant connections
and describes the failure-domain choices in
[FastConnect redundancy best practices](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/fastconnectresiliency.htm).

FastConnect requires Layer-3 BGP-capable equipment and an existing physical or
partner connection. Review
[FastConnect requirements](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/fastconnectrequirements.htm)
before scheduling activation.
