# Oracle Integration Cloud disaster recovery with Terraform

This configuration deploys a primary and a secondary Oracle Integration Cloud (OIC) environment, with DNS failover and scheduled replication from primary to secondary.

It creates the following in each workload region:

1. An OIC instance and the Identity Domains application created for it by OIC.
2. A confidential OAuth client application. The client is granted the `ServiceAdministrator` role from its own region's OIC application and is configured with the OIC resource application's scopes.
3. A VCN, public subnet, internet gateway, NAT gateway, and regional load balancer. The secondary VCN also includes a private Functions subnet for the replication Function.
4. An imported custom-hostname listener certificate in each workload region. Terraform reads each OIC endpoint's server certificate and CA chain automatically after the instance is created for encrypted load-balancer-to-OIC traffic.

It also creates a global DNS zone, a primary/secondary failover steering policy, and—in the secondary region—an OCI Function, Object Storage bucket, IAM dynamic groups and policies, and an hourly Resource Scheduler job. The function exports integrations from the primary OIC instance and imports them into the secondary instance.

## Prerequisites

- Terraform `>= 1.5.0`
- OCI API-key credentials with permission to manage the resources above, including tenancy-level IAM policies and dynamic groups
- An existing OCI Identity Domain
- Two OCI regions that can host the selected OIC shape
- The `dig` command available on the machine running Terraform; it resolves each OIC endpoint while creating regional networking
- Docker and an OCI auth token for an OCI user that can push to OCIR; these are used to publish the replication Function image described below
- A TLS certificate, its private key, and a CA/intermediate chain for the regional HTTPS load balancers


### TLS materials and domain hostname

Before running Terraform, choose the public hostname that will be used for the OIC custom endpoints and set it as `domain_hostname` in `terraform.tfvars`. The TLS certificate must be issued for that hostname (its CN or SAN must match `domain_hostname`). Replace the placeholder PEM content in these files, or set the corresponding path variables in `terraform.tfvars`:

- [`ssl/server-certificate.pem`](./ssl/server-certificate.pem): public TLS server certificate
- [`ssl/ca-chain.pem`](./ssl/ca-chain.pem): CA and intermediate certificate chain for the listener certificate
- [`ssl/private-key.pem`](./ssl/private-key.pem): private key for the server certificate

The custom-hostname certificate is imported into OCI Certificates in both workload regions for the public listeners. During the same apply, Terraform connects to each OIC instance URL and uses the live server certificate and CA chain to create a load-balancer-managed backend certificate; no manually downloaded OIC backend certificate files are needed. Backend traffic is encrypted on port 443, but peer-certificate verification is disabled by the load-balancer configuration. The backend health check is TCP on port 443.

## Deploy

### 1. Confirm the domain and TLS configuration

Before continuing, ensure that `terraform.tfvars` contains the intended `domain_hostname`, all required root-variable values, and paths to the matching certificate, private key, and CA/intermediate chain.
Search for TODOs in `terraform.tfvars` and in files under `ssl/` folder and replace them with required values.

### 2. Create and publish the replication Function image

Before the first Terraform run, create a **private** OCIR repository named `oci-dr-replication` in the secondary region and the compartment in which you will run this deployment. In the OCI Console, go to **Developer Services → Container Registry**, select the secondary region, and choose **Create repository**.

The Terraform Function definition uses this exact image reference:

```
<secondary_region>.ocir.io/<namespace>/oic-dr-replication:1.0.0
```

Authenticate Docker to the secondary-region registry using an OCI auth token, then build the Dockerfile under `modules/oic_dr_replication_function/function` and push the required tag. Replace the placeholder values below with your secondary region, Object Storage namespace, and OCI username.

```bash
docker login <secondary_region>.ocir.io \
  --username '<namespace>/<oci_username>'

docker build \
  --tag <secondary_region>.ocir.io/<namespace>/oic-dr-replication:1.0.0 \
  modules/oic_dr_replication_function/function

docker push <secondary_region>.ocir.io/<namespace>/oic-dr-replication:1.0.0
```

### 3. Initialize and apply Terraform

From the repository root, run:

```bash
terraform init
terraform plan
terraform apply
```

The first `terraform apply` can fail while the `tls` data source retrieves certificates from a newly created OIC instance. That data source does not wait for the integration instances to become available. If this happens, wait for both OIC instances to be up, then run `terraform apply` again.

### 4. Configure the OIC custom endpoints

After the apply completes and both OIC instances are available, manually configure a customer-managed custom endpoint for **each** OIC instance in the OCI Console. For both endpoints, use the hostname supplied as `domain_hostname` in `terraform.tfvars` and point the endpoint at the appropriate regional load balancer. This Terraform configuration does not create OIC custom endpoints. See [Create a Custom Endpoint for OIC v3](https://www.ateam-oracle.com/post/create-a-custom-endpoint-for-oic-v3) for the console workflow.

### 5. Add and activate the sample Echo Request integration

After Terraform finishes, manually add the sample **Oracle REST Echo Request** integration to the **primary** OIC instance and activate it in the OIC console. Follow the [Configure a sample integration](https://www.ateam-oracle.com/test-connectivity-oic-v3#configure-a-sample-integration) section of Oracle's guide: open **Browse store**, search for `echo`, choose **Get**, open **Projects → Oracle REST Echo Request**, and select **Activate**. The scheduled Function copies it to the secondary instance on its next hourly run; wait for that run (or invoke the Function manually) before testing secondary failover.

### 6. Verify the deployment

After completing the previous steps, open the following URL, replacing `<domain_hostname>` with the value in `terraform.tfvars`:

```
https://<domain_hostname>/ic/api/integration/v2/flows/rest/project/ORCL-R-REST_ECHO_REQUEST/ORCL-R-SAMPLE_ECHO/1.0/metadata/openapi
```

A successful request returns the Echo Request integration's OpenAPI metadata as a JSON document.

Terraform creates the global DNS zone through the `oci.home` provider, which must use the tenancy home region. Delegate `domain_hostname` to the nameservers assigned by OCI. The zone apex is an A record for the primary load balancer; the steering-policy attachment uses the configured zone hostname and has primary and secondary answer pools. The HTTPS health monitor runs every 10 seconds with a 10-second timeout against the configured OIC REST metadata path and returns the highest-priority healthy pool.

## Outputs

The configuration exposes the following outputs:

| Category | Outputs |
| --- | --- |
| OIC instances | `primary_oic_instance_id`, `primary_oic_instance_url`, `primary_oic_primary_audience_url`, `primary_oic_generated_app_id`, `secondary_oic_instance_id`, `secondary_oic_instance_url`, `secondary_oic_primary_audience_url`, `secondary_oic_generated_app_id` |
| OAuth client applications | `primary_oauth_client_app_id`, `primary_oauth_client_name`, `secondary_oauth_client_app_id`, `secondary_oauth_client_name` |
| Network | `primary_vcn_id`, `primary_public_subnet_id`, `primary_internet_gateway_id`, `primary_nat_gateway_id`, `secondary_vcn_id`, `secondary_public_subnet_id`, `secondary_functions_subnet_id`, `secondary_internet_gateway_id`, `secondary_nat_gateway_id` |
| Load balancers | `primary_load_balancer_public_ip`, `secondary_load_balancer_public_ip` |
| DNS failover | `dns_failover_steering_policy_id`, `dns_failover_health_check_monitor_id`, `dns_failover_zone_id`, `dns_failover_steering_policy_attachment_id` |
| Replication | `oic_dr_replication_function_id`, `oic_dr_replication_schedule_id` |
| Sensitive OAuth values | `primary_oauth_client_secret`, `secondary_oauth_client_secret`, `primary_oic_bearer_token`, `secondary_oic_bearer_token` |
| OAuth token lifetimes | `primary_oic_bearer_token_expires_in`, `secondary_oic_bearer_token_expires_in` |

Only the OAuth client secrets and bearer-token values are marked sensitive. Store Terraform state in an encrypted, access-controlled backend.

## Replication behavior and security

The scheduler invokes the Function at minute zero of every hour (UTC). On each invocation, the function requests fresh OAuth tokens using the two regional OAuth clients, lists integration versions and projects in both instances, deletes all versions and projects from the secondary instance, exports primary archives to the private `oic-dr` Object Storage bucket, reads each archive back, and imports it into secondary.

Replication is destructive for the secondary instance: integrations and projects that exist only in secondary are removed on each run. It does not replicate standalone connections, lookups, libraries, packages, certificates, or agents. Test the workflow in non-production before relying on it for disaster recovery.

Terraform state contains OAuth client secrets and the bearer tokens obtained during `terraform apply`. Store state in an encrypted, access-controlled backend. The Function does not use Terraform's short-lived bearer-token outputs; it obtains fresh tokens at runtime.
