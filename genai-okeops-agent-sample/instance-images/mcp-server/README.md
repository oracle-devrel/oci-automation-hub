<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# OCI OKE MCP Server

FastMCP server providing OCI inventory, compute, networking, and OKE tools. The [container stack](../../container-instance-stack/) deploys it as a private OCI Container Instance.

## Endpoints

| Endpoint | Purpose |
| --- | --- |
| `/mcp` | MCP Streamable HTTP, using the [FastMCP default path](https://github.com/PrefectHQ/fastmcp/blob/main/docs/deployment/http.mdx) |
| `/healthz` | HTTP health check |
| `/ready` | Readiness route |

The server listens on port `8080`. The health/readiness routes return service status; they do not test OCI permissions or Kubernetes connectivity.

## Dependencies and local execution

Install Python 3.11 or newer, `uv`, OCI CLI, and `kubectl`. `pyproject.toml` and `uv.lock` define the Docker dependency set; the legacy `requirements.txt` is not used by the Dockerfile.

From this directory, with OCI profile credentials configured:

```sh
export OCI_CLI_PROFILE="<profile>"
export OCI_TENANCY_ID="<tenancy-OCID>"
# Set the deployed RAG agent endpoint to enable tools that use it.
export AGENT_ENDPOINT_ID="<agent-endpoint-OCID>"
uv sync --frozen --no-dev --python 3.11
uv run --frozen python app.py
```

The app first attempts resource-principal authentication, then falls back to `OCI_CLI_PROFILE` in the local OCI config. There is no `.env.example` in this directory; set variables directly or create a local ignored `.env` file. Local execution needs credentials and network access for the OCI services used by the tools.

After changing dependencies, regenerate and check the lock file:

```sh
uv lock
uv lock --check
```

## Docker

```sh
docker buildx build --platform linux/amd64 --load -t oci-oke-mcp:local .
```

Match the target architecture to the Container Instance shape. The Dockerfile installs kubectl using its `KUBECTL_VERSION` build argument; select a released version compatible with your cluster when overriding the existing default:

```sh
docker buildx build --platform linux/amd64 --build-arg KUBECTL_VERSION="<compatible-version>" --load -t oci-oke-mcp:local .
```

For OCIR publishing, use the commands in the [root README](../../README.md#2-build-and-push-images).

## OCI deployment and OKE access

The container stack sets `OCI_TENANCY_ID` and `AGENT_ENDPOINT_ID`. Use resource-principal authentication and grant the container identity the required OCI and Kubernetes permissions. The infrastructure stack currently grants its container dynamic group broad compartment access; review those policies for your deployment.

The container NSG allows port 8080 from the UI NSG. Connect the UI to `http://<mcp-private-ip>:8080/mcp`. For Kubernetes operations, use the server's `get_cluster` and `create_kubeconfig` tools before `run_kubectl`; select `PUBLIC_ENDPOINT` or `PRIVATE_ENDPOINT` according to the cluster. The MCP subnet must be permitted to reach the Kubernetes API on TCP 6443.

From a host with private network access, check process health:

```sh
curl --fail "http://<mcp-private-ip>:8080/healthz"
```
