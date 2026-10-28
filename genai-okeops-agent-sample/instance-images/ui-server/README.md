<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# OCI Agent App Server

FastAPI backend and browser chat UI with SQLite conversation storage, OCI Generative AI / Enterprise AI integration, MCP tools, RAG, and OCI Identity Domain sign-in.

The container listens on port `8000`; local Compose publishes `http://localhost:8080`. In OCI, the [container stack](../../container-instance-stack/) terminates TLS at the load balancer and sets `APP_BASE_URL` to its public HTTPS URL.

## Build

Run from this directory:

```sh
docker buildx build --platform linux/amd64 --load -t oci-agent-ui:local .
```

Match the architecture to your target shape. Follow the [root README](../../README.md#2-build-and-push-images) to push images to OCIR.

## Configuration

| Variable | Purpose |
| --- | --- |
| `OCI_IDENTITY_DOMAIN_ISSUER` | Identity Domain issuer URL |
| `OCI_OIDC_CLIENT_ID` | Confidential application client ID |
| `OCI_OIDC_CLIENT_SECRET` | Confidential application client secret |
| `APP_BASE_URL` | Browser-facing URL; defaults to `http://localhost:8080` |
| `APP_DATA_DIR` | SQLite storage directory; defaults to `/app/data` |
| `PORT` | Backend listening port; defaults to `8000` |

Authentication is enabled in application code. The redirect URI is derived as `${APP_BASE_URL}/auth/callback`; secure-cookie behavior follows whether that URL uses HTTPS. The container stack supplies the OIDC settings and the deployed base URL.

OCI API access uses resource-principal authentication. The UI does not load a local OCI CLI profile as a fallback. Register the confidential application's redirect URI for the actual URL used by the browser and grant the runtime identity access to the selected OCI services.

## Local Compose health and sign-in checks

There is no `.env.example` in this directory. Create a local `.env` with the three OIDC values required by Compose:

```dotenv
OCI_IDENTITY_DOMAIN_ISSUER=https://<identity-domain-issuer>
OCI_OIDC_CLIENT_ID=<client-id>
OCI_OIDC_CLIENT_SECRET=<client-secret>
```

Register `http://localhost:8080/auth/callback` on the confidential application, then run:

```sh
docker compose up --build
curl --fail http://localhost:8080/healthz
```

Compose passes the three OIDC variables above and persists `/app/data` in its `app-data` volume. The Docker/Compose health check uses `http://127.0.0.1:8000/healthz` inside the container. A workstation container has no OCI resource principal by default, so a successful local health or sign-in check does not establish that OCI model/tool calls will work. Full OCI functionality requires a runtime with a configured resource principal and service permissions.

## Post-deployment setup

Open the container stack's `app_url` output and sign in. Select region, compartment, project/model, and RAG resources in the UI. Add the deployed MCP server using its private URL `http://<mcp-private-ip>:8080/mcp`, discover its tools, and select the tools to enable.

The backend supports local LangGraph MCP calls. OCI-hosted MCP connector execution additionally requires connectivity from that service to the MCP endpoint; private UI-to-MCP connectivity alone is insufficient.

In OCI, the current Terraform configuration stores SQLite data in the container filesystem. It does not provision persistent storage for that data, so container replacement can discard conversations and saved UI configuration. Local Compose uses a persistent Docker volume.
