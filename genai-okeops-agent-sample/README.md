<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# OCI GenAI OKE Operations Agent

Terraform stacks and container images for an OCI assistant that combines Generative AI, MCP tools, RAG, and OKE troubleshooting.

Deploy in this order:

1. Apply `infrastructure-stack` to create OKE, the demo workload, an alarm and stream, Generative AI Agent/RAG resources, and container repositories.
2. Build and push the MCP and UI images to those repositories.
3. Apply `container-instance-stack` to create the containers, HTTPS load balancer, and Identity Domain application.
4. Sign in to the UI and configure the model, MCP server, and RAG resources.

A successful Terraform plan confirms proposed resources and configuration. Runtime checks after deployment establish worker readiness, application connectivity, alarm firing, and stream delivery.

## Repository layout

| Path | Contents |
| --- | --- |
| [infrastructure-stack](infrastructure-stack/) | OKE, IAM, Logging, Service Connector, Streaming, Generative AI Agent/RAG, and OCIR repositories |
| [infrastructure-stack/oke-workload.tf](infrastructure-stack/oke-workload.tf) | Demo namespace and deliberately unschedulable pod |
| [infrastructure-stack/network.tf](infrastructure-stack/network.tf) | OKE endpoint and worker NSGs |
| [infrastructure-stack/kb-file/kb-file.pdf](infrastructure-stack/kb-file/kb-file.pdf) | Seed knowledge-base document |
| [container-instance-stack](container-instance-stack/) | MCP/UI Container Instances, Identity Domain app, certificate import, and load balancer |
| [container-instance-stack/network.tf](container-instance-stack/network.tf) | Load balancer, UI, and MCP NSGs |
| [instance-images/mcp-server](instance-images/mcp-server/README.md) | MCP tools, Dockerfile, `pyproject.toml`, and `uv.lock` |
| [instance-images/ui-server](instance-images/ui-server/README.md) | FastAPI backend, browser UI, Dockerfile, and Compose configuration |

Each stack has `variables.tf`, `output.tf`, and a Resource Manager `schema.yaml`.

## Prerequisites

- Terraform 1.5 or newer, OCI CLI, and OCI credentials for the deployment identity.
- Docker with Buildx for image builds, an OCIR auth token, and `kubectl` for workload verification.
- An existing VCN with public and private subnets in the deployment region.
- NAT or equivalent outbound routing for private image pulls, service access, and an internet gateway route for the public load balancer/API endpoint.
- Permissions to manage OKE, compute, networking, IAM, Container Instances, OCIR, Streaming, Monitoring, Logging, Object Storage, Generative AI Agents, and the selected Identity Domain application.
- Kubernetes API access from the Terraform runner and the MCP container identity. Keep this access available for updates and destruction.
- A TLS certificate, CA chain, and matching private key for certificate import. The current stack reads `wildcard-app.crt`, `wildcard-ca.crt`, and `wildcard-app.key` from `container-instance-stack/modules/certificates/`. Use deployment-specific material and keep private keys out of Git. The current app URL uses the load balancer's public IP; a wildcard DNS certificate does not validate an IP address.

## Network configuration

The stacks create and attach NSGs to the OKE endpoint, workers, load balancer, UI, and MCP server. Subnet CIDRs come from OCI data sources; load balancer/UI/MCP rules reference NSGs. Existing subnet security lists continue to apply. Gateways and route tables are prerequisites.

| Destination | Allowed source | Traffic |
| --- | --- | --- |
| OKE endpoint | Worker subnet | TCP 6443 and 12250 |
| OKE endpoint | MCP subnet | TCP 6443 |
| OKE endpoint | `kubernetes_api_client_cidrs` | TCP 6443 |
| OKE workers | Worker subnet | All protocols for worker/pod communication |
| OKE workers | Endpoint subnet | TCP, all ports |
| OKE endpoint/workers | Peer subnet | ICMP type 3, code 4 for path discovery |
| HTTPS load balancer | `app_client_cidrs` | TCP 443 |
| UI | Load balancer NSG | TCP 8000, including `/healthz` checks |
| MCP | UI NSG | TCP 8080 |

NSGs permit stateful outbound access through existing routes. Both client allowlists default to empty. Configure trusted CIDRs for the runner and browser. For workstation access, supply your current public IPv4 address with a `/32` prefix in the appropriate client allowlist.

The infrastructure variable `mcp_subnet_id` defaults to `oke_worker_subnet_id`. Set it to the container stack's `app_subnet_id` when different. The current container stack puts UI and MCP in the same subnet. Keep endpoint, worker, and container subnets in the same VCN for this sample. The stack does not create Kubernetes NodePort services.

See Oracle's [OKE network requirements](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfig.htm) and [Flannel networking example](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfigexample.htm).

## 1. Deploy infrastructure

For local Terraform, create `infrastructure-stack/terraform.tfvars` using the inputs defined in `infrastructure-stack/variables.tf`, then initialize:

```sh
terraform -chdir=infrastructure-stack init
```

Choose an OKE-supported Kubernetes version and a matching worker image for the selected shape. Discover current options with your configured OCI profile and region:

```sh
oci ce cluster-options get --cluster-option-id all
oci ce node-pool-options get --node-pool-option-id all
```

The stack creates a basic OKE cluster with Flannel networking. Workers default to one node with 2 OCPUs and 16 GB RAM. A public API endpoint requires a public subnet; a private endpoint requires a VCN-connected Terraform runner.

For local OCI profile authentication:

```sh
export OCI_CONFIG_FILE_PROFILE="<profile>"
export OCI_CLI_PROFILE="$OCI_CONFIG_FILE_PROFILE"
terraform -chdir=infrastructure-stack validate
terraform -chdir=infrastructure-stack plan -var-file=terraform.tfvars -out=deployment.tfplan
terraform -chdir=infrastructure-stack apply deployment.tfplan
```

Populate `kubernetes_api_client_cidrs` before planning directly. Set `kubernetes_cli_auth = "api_key"` for local CLI credentials.

### Resource Manager alternative

Create a Resource Manager stack from the `infrastructure-stack` folder. Supply the variables exposed by `schema.yaml`, including supported Kubernetes version/image, VCN/subnets, and the Kubernetes API client allowlist. Use `kubernetes_cli_auth = "resource_principal"` for Resource Manager. Its runner needs OCI CLI, network access to the Kubernetes API, and appropriate OCI/Kubernetes permissions. For a private endpoint, configure Resource Manager private network access. Run a plan, review it, and apply.

Generative AI Agent provisioning and document ingestion can take more than 30 minutes. Collect these outputs when apply finishes:

| Output | Use |
| --- | --- |
| `mcp_ocir_repository_url`, `app_ocir_repository_url` | Build/push image destinations |
| `rag_agent_endpoint` | Container variable `rag_agent_endpoint_id` |
| `oke_cluster_id`, `oke_node_pool_id` | Cluster access and verification |
| `stream_service_id` | Destination stream OCID |
| `unschedulable_pod`, `unschedulable_pods_alarm_id` | Demo verification |

### Unschedulable pod and alarm

The stack creates namespace `okeops-demo` and pod `unschedulable-demo`. The pod requires node label `okeops.oracle.com/demo-target=nonexistent`, which the stack does not assign to workers. Terraform accepts `Pending` as the intended pod state; it does not establish that a `FailedScheduling` event has occurred.

The enabled alarm uses namespace `oci_oke` and this query, substituting the created cluster OCID:

```text
UnschedulablePods[1m]{resourceId = "<cluster-ocid>"}.max() > 0
```

The [native OKE metric](https://docs.oracle.com/en-us/iaas/Content/ContEng/Reference/contengmetrics.htm) counts unschedulable pods across the cluster. A single unschedulable pod can breach the threshold. The alarm has a one-minute pending duration and sends RAW JSON directly to the created stream. The Logging/Service Connector pipeline is separate from this alarm delivery path. Pod names and scheduling failure details come from Kubernetes events, rather than from this metric.

After deployment, use the actual outputs to verify:

```sh
cluster_id="$(terraform -chdir=infrastructure-stack output -raw oke_cluster_id)"
alarm_id="$(terraform -chdir=infrastructure-stack output -raw unschedulable_pods_alarm_id)"
stream_id="$(terraform -chdir=infrastructure-stack output -raw stream_service_id)"
oci ce cluster create-kubeconfig --cluster-id "$cluster_id" --file /tmp/okeops-kubeconfig --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT
export KUBECONFIG=/tmp/okeops-kubeconfig
kubectl get nodes
kubectl -n okeops-demo describe pod unschedulable-demo
kubectl -n okeops-demo get events --field-selector reason=FailedScheduling
oci monitoring alarm get --alarm-id "$alarm_id"
oci monitoring alarm-history-collection get-alarm-history --alarm-id "$alarm_id"
stream_endpoint="$(oci streaming admin stream get --stream-id "$stream_id" --query 'data."messages-endpoint"' --raw-output)"
cursor="$(oci streaming stream cursor create-cursor --stream-id "$stream_id" --partition 0 --type TRIM_HORIZON --endpoint "$stream_endpoint" --query data.value --raw-output)"
oci streaming stream message get --stream-id "$stream_id" --cursor "$cursor" --endpoint "$stream_endpoint"
```

Use `PRIVATE_ENDPOINT` for a private API endpoint. Confirm Ready workers, `PodScheduled=False` with reason `Unschedulable`, a `FailedScheduling` event, a FIRING alarm, and a matching alarm message in Streaming. Allow several minutes for metrics and evaluation. Stream message values are base64-encoded; decode them to inspect the alarm ID and status. Continue with the next cursor if the first batch contains older messages.

Delete the demo pod to clear its contribution with `kubectl -n okeops-demo delete pod unschedulable-demo`. A later Terraform apply recreates it. Other unschedulable pods can keep the alarm firing.

## 2. Build and push images

Run from the repository root after infrastructure apply. The following commands build AMD64 images for the sample's `CI.Standard.E4.Flex` containers. Choose an appropriate image architecture if changing the shape.

```sh
mcp_repository="$(terraform -chdir=infrastructure-stack output -raw mcp_ocir_repository_url)"
app_repository="$(terraform -chdir=infrastructure-stack output -raw app_ocir_repository_url)"
docker login "${mcp_repository%%/*}"
docker buildx build --platform linux/amd64 -t "$mcp_repository:latest" --push instance-images/mcp-server
docker buildx build --platform linux/amd64 -t "$app_repository:latest" --push instance-images/ui-server
```

Use the OCIR username and an OCI auth token for registry login. MCP builds use `pyproject.toml` and the committed `uv.lock`; see the [MCP README](instance-images/mcp-server/README.md) for dependency updates and the configurable kubectl version.

## 3. Deploy containers

For local Terraform, create `container-instance-stack/terraform.tfvars` using the inputs defined in `container-instance-stack/variables.tf`, then initialize:

```sh
terraform -chdir=container-instance-stack init
```

Supply your tenancy, compartment, availability domain, Identity Domain, subnets, shape, and image URLs. Set `rag_agent_endpoint_id` to the infrastructure output `rag_agent_endpoint`. UI and MCP use `app_subnet_id`; the public load balancer uses `lb_subnet_id`. Configure `app_client_cidrs` for browser access and provide the TLS material described above.

```sh
terraform -chdir=container-instance-stack validate
terraform -chdir=container-instance-stack plan -var-file=terraform.tfvars -out=deployment.tfplan
terraform -chdir=container-instance-stack apply deployment.tfplan
terraform -chdir=container-instance-stack output -raw app_url
```

Alternatively, create a Resource Manager stack from `container-instance-stack`, supply its schema variables, run a plan, and apply. OIDC client credentials and redirect URLs are created and passed to the UI by this stack.

### Configure the UI

Open `app_url` and sign in through the selected Identity Domain. Configure region, compartment, model/project, the private MCP URL `http://<mcp-private-ip>:8080/mcp`, and RAG resources in the UI. Discover the MCP container's VNIC/private IP through OCI; the current root outputs expose the UI private IP, not the MCP private IP.

The UI backend can invoke MCP tools through its local LangGraph path. OCI-hosted MCP connector execution additionally requires connectivity from that service to the MCP endpoint; the UI-to-MCP NSG rule alone does not provide it. The infrastructure provisions the Generative AI Agent and RAG resources, while UI model/tool selection remains a post-deployment step.

See the [UI README](instance-images/ui-server/README.md) for local health checks, authentication, and storage behavior.

## Cleanup and upgrades

Destroy the container stack first, then infrastructure, using the same credentials and variables used for deployment. Keep the Kubernetes API reachable while Terraform removes the demo pod and namespace. For Resource Manager, run Destroy jobs in the same order.

When upgrading a deployment that still manages the former two test VMs, review the planned VM deletions and OKE creation before applying. The old VM file-log agent configuration has been removed; Logging, Service Connector, and Streaming remain available for additional log producers.

## Files to commit

Commit Terraform/Python source, Markdown, and provider/dependency lock files. Local `.tfvars`, saved plans, Terraform state, `.terraform` directories, `.env` files, and editor settings are ignored. Review existing certificate/private-key files separately before publishing; ignoring a file does not untrack it.
