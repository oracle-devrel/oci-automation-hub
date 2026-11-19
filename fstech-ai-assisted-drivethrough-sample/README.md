<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# FSTech AI-Assisted Drive-Thru

This repository provides the necessary Terraform configuration and runtime application artifacts to deploy an AI-powered drive-thru ordering assistant on Oracle Cloud Infrastructure (OCI). The solution combines OCI Generative AI Agents, OCI Vision, OCI Speech, Autonomous AI Database 26ai, Object Storage, ORDS REST APIs, and a browser-based application runtime to create a personalized drive-thru ordering experience.

The solution deploys:

* OCI Generative AI Agent and session-enabled Agent Endpoint
* Six Terraform-managed function tools for order history, offers, weather, order lookup, order insertion, and vehicle registration extraction
* Autonomous AI Database 26ai with `ORDER_DETAILS` and `OFFERS`
* ORDS REST APIs for order history, offer search, order lookup, and order insertion
* OCI Vision integration for vehicle registration recognition
* OCI Speech STT and TTS integration using the `Victoria` voice
* Oracle Linux application VM running FastAPI, Next.js, Nginx, and systemd services
* Object Storage bucket for runtime and wallet bootstrap artifacts
* Dynamic group and runtime IAM policy for instance-principal access
* Optional dedicated VCN, public subnet, Internet Gateway, route table, and Network Security Group

# How It Works

The repository is structured as a Terraform-based Resource Manager stack combined with a bootstrapped application runtime.

* `compartments.tf`:
  * Creates Network, Data, AI, and Application child compartments under the selected parent compartment.
* `network.tf`:
  * Uses an existing VCN/public subnet or creates a dedicated VCN and public subnet from user-supplied CIDRs.
  * Creates the application Network Security Group.
* `database.tf`:
  * Creates Autonomous AI Database 26ai.
  * Generates the ADMIN and wallet passwords.
* `genai.tf`:
  * Creates or reuses a Generative AI Agent and endpoint.
  * Creates the six function-calling tools used by the runtime.
* `storage.tf`:
  * Creates the private Object Storage bucket.
  * Uploads the runtime bundle and ADB wallet.
  * Creates temporary pre-authenticated bootstrap URLs.
* `compute.tf`:
  * Renders cloud-init user data.
  * Creates the Oracle Linux application VM.
* `iam.tf`:
  * Creates the runtime dynamic group and IAM policy.
  * Grants access to GenAI Agents, Vision, Speech, Object Storage, and Agent sessions.
* `templates/app.cloud-init.tftpl`:
  * Installs OS packages, Node.js, Python dependencies, Nginx, and systemd services.
  * Downloads the runtime bundle and ADB wallet onto the VM.
* `runtime/`:
  * Contains FastAPI, GenAI tool reconciliation, ADB/ORDS initialization, startup scripts, seed CSV files, and the Next.js UI.
* `iam/`:
  * Contains optional deployer-policy guidance for non-administrator stack deployment.
* `schema.yaml`:
  * Provides the OCI Resource Manager guided deployment form.

The solution works as follows:

1. A customer uses the browser-based drive-thru UI.
2. The UI sends text, image, or voice requests to the FastAPI service.
3. FastAPI invokes the OCI Generative AI Agent endpoint.
4. The Agent calls Terraform-managed function tools when it needs order history, offers, weather, order lookup, order insertion, or vehicle registration extraction.
5. Runtime tools use OCI Vision, Open-Meteo weather data, and ORDS APIs backed by Autonomous AI Database.
6. OCI Speech handles speech-to-text and text-to-speech for voice interactions.
7. The Agent returns a personalized ordering response to the UI.

# Solution Deployment

The solution is deployed as a single OCI Resource Manager stack. Terraform creates the supporting OCI resources and the application VM bootstraps itself with cloud-init.

1. Deploy the Resource Manager stack.
2. Wait for the application VM bootstrap to finish.
3. Validate the application URL and health endpoint.

## Prerequisites

* Access to an OCI tenancy and a clean parent compartment.
* Permission to create child compartments, IAM policies, dynamic groups, networking, Object Storage, Autonomous Database, Generative AI Agent resources, and compute instances.
* OCI Resource Manager with Terraform 1.5.x.
* A deployment region where the following services are available:
  * OCI Generative AI Agents
  * Autonomous AI Database 26ai
  * OCI Vision
  * OCI Speech STT/TTS with the `Victoria` voice
* Compute quota for the selected VM shape.
  * The default shape is `VM.Standard.E4.Flex`.
  * `VM.Standard.E5.Flex` is also supported by the Resource Manager schema.
* Network choice:
  * Existing VCN and public subnet, or
  * New VCN and public subnet CIDRs supplied during stack creation.
* Optional SSH public key for diagnostics.

If deploying as a non-administrator, an administrator must first grant the required deployment permissions. See [`iam/README.md`](iam/README.md).

## Part 1: Deploy the Resource Manager Stack

**Note:** The following steps deploy the complete OCI drive-thru stack, including compartments, database, AI Agent resources, object storage, IAM, networking, and application runtime.

1. Zip the contents of this directory.
   * Keep `runtime/`, `templates/`, `schema.yaml`, and all Terraform files at the ZIP root.
2. Use Oracle Resource Manager to create and apply the stack.
   * Using the hamburger menu, go to Oracle Resource Manager.
   * Choose `Stacks`.
   * Click `Create stack`.
   * Select `My configuration`.
   * In the configuration section, select folder or ZIP upload.
   * Upload the ZIP created from this directory.
   * Provide a meaningful stack name.
   * Click `Next`.
   * Choose the clean parent `compartment`.
   * Confirm the Resource Manager stack region.
   * Provide the required variables:
     * Parent application compartment
     * Network choice
     * Existing VCN/subnet values or new VCN/subnet CIDRs
     * Optional resource name prefix
     * Optional SSH public key
     * Optional VM and ADB sizing
     * Optional existing GenAI Agent endpoint values if reusing an Agent
   * Click `Next`.
   * Select `Run apply`.
   * Click `Create`.
3. Wait for the Terraform apply job to complete successfully.
4. Wait 10-20 minutes for cloud-init to finish first boot on the application VM.
5. After deployment, collect the stack outputs:
   * `application_url`
   * `bootstrap_health_url`
   * `application_public_ip`
   * `genai_agent_id`
   * `genai_agent_endpoint_id`
   * `ords_rest_apis`
   * `database_verification_sql`
   * `bootstrap_status_command`

## Network Selection

The stack supports two network modes.

### Existing Network

Use this mode to deploy the application VM into an existing VCN and public subnet.

Required inputs:

* Existing network compartment
* Existing VCN
* Existing public subnet

The subnet must:

* Belong to the selected VCN
* Permit public IP addresses
* Route `0.0.0.0/0` through an Internet Gateway

The stack creates an application Network Security Group but does not edit the existing subnet route table or security lists.

### Dedicated Network

Use this mode to let Terraform create the VCN and public subnet.

Required inputs:

* New VCN CIDR
* New public subnet CIDR

The stack creates:

* VCN
* Internet Gateway
* Public route table
* Public subnet
* Application Network Security Group

No CIDR values are embedded in the stack. Choose non-overlapping ranges if future peering or transitive routing is planned.

## Compartment Layout

The selected `compartment_ocid` is treated as a parent compartment. Terraform creates four child compartments and places resources by responsibility:

~~~text
Selected parent compartment
├── fstech-network      Created VCN resources or the app NSG for an existing VCN
├── fstech-data         Autonomous AI Database 26ai
├── fstech-ai           Generative AI Agent and endpoint
└── fstech-application  Compute runtime, Speech jobs, and Object Storage
~~~

The prefix follows `name_prefix`, so separate environments can use prefixes such as `fstdev`, `fsttest`, and `fstprod`.

## Existing GenAI Agent Quota

If Plan or Apply reports `LimitExceeded: agent-count`, either delete an unused Agent, request a service-limit increase, or reuse an existing endpoint.

To reuse an endpoint:

1. Set `create_genai_agent` to `false`.
2. Set `existing_agent_id` to the parent Agent OCID.
3. Set `existing_agent_endpoint_id` to the endpoint OCID.
4. Set `existing_agent_compartment_ocid` to the compartment containing the Agent.

Terraform will skip Agent creation, attach the six function tools to the supplied parent Agent, and grant the runtime dynamic group access to that compartment.

# Post-Installation

Once the deployment is complete, open the `application_url` output in a browser.

The AI-assisted drive-thru application can be used for:

* Personalized food and drink recommendations
* Returning-customer lookup by vehicle registration number
* Vehicle registration extraction from uploaded images
* Current-offer search
* Weather-aware recommendations
* Voice interaction through OCI Speech STT and TTS
* Confirmed order insertion into Autonomous AI Database through ORDS

The `bootstrap_health_url` output reports readiness. A complete deployment returns JSON containing:

* `"database":"ready"`
* `"schema":"ADMIN"`
* `"order_rows":2000` or more
* `"offer_rows":25` or more

During first boot, the health URL can remain unavailable for 10-20 minutes.

## Runtime Behavior

The instance downloads the versioned application bundle, opens the generated ADB wallet, connects as the automatically provisioned `ADMIN` account, merges both CSV files into `ADMIN.ORDER_DETAILS` and `ADMIN.OFFERS`, and defines the ORDS routes before starting the API.

The deployment seed files are bundled at:

* `runtime/seed/order_details.csv`
* `runtime/seed/offers.csv`

Initialization is idempotent and verifies the expected seed counts before the API starts.

The expected ORDS module is `drive_thru`, owned by `ADMIN`, and published below the `/ords/admin/api/` base path.

The module publishes four REST APIs:

* `GET /ords/admin/api/get_order_history?registration_number=NCK6686`
* `GET /ords/admin/api/search_offers?registration_number=NCK6686`
* `GET /ords/admin/api/get_orders`
* `POST /ords/admin/api/insert_order`

The complete deployment-specific URLs are returned by the `ords_rest_apis` Terraform output.

## Services, Ports, and Request Flow

Only TCP port 80 is opened publicly. Nginx is the public entry point and routes requests internally:

~~~text
Browser :80 -> Nginx
             ├── / and UI assets -> Next.js 127.0.0.1:3000
             ├── /api/*           -> FastAPI 127.0.0.1:8000
             └── /health          -> FastAPI 127.0.0.1:8000/health
~~~

The relevant services are:

* `fstech-api.service`: initializes ADB/ORDS and GenAI tools, then runs FastAPI.
* `fstech-ui.service`: verifies or builds the UI if needed, then runs Next.js.
* `nginx.service`: publishes the unified application on port 80.

## VM Installation and File Layout

Cloud-init installs:

* Python 3.11, `pip`, and virtual environment tooling
* Nginx, `unzip`, `xz`, and SELinux/firewall support tools
* Node.js 22.14.0 and npm from the official Node.js binary distribution

The resulting VM layout is:

~~~text
/opt/fstech/
├── app/                    Extracted application runtime
│   ├── web_api.py          FastAPI text, image, STT, and TTS bridge
│   ├── agent-codex-working.py
│   ├── agent_init.py       GenAI tool reconciliation and verification
│   ├── db_init.py          Tables, CSV seed data, and ORDS setup
│   ├── seed/               Bundled order_details.csv and offers.csv
│   ├── ui/                 Next.js browser application
│   ├── start-backend.sh
│   └── start-ui.sh
├── venv/                   Python virtual environment and dependencies
├── wallet/                 Extracted ADB client wallet
├── runtime.zip             Downloaded application bundle
└── wallet.zip              Downloaded wallet archive

/etc/fstech.env             Generated runtime configuration
/etc/systemd/system/fstech-api.service
/etc/systemd/system/fstech-ui.service
/etc/nginx/conf.d/fstech.conf
~~~

`/etc/fstech.env` contains generated endpoints and database credentials. Do not print it, copy it into tickets, or commit it.

## Instance Diagnostics

If bootstrap is still running or the health check is unavailable, use these read-only commands on the instance:

~~~bash
sudo cloud-init status --long
sudo tail -n 300 /var/log/cloud-init-output.log

sudo systemctl status fstech-api.service --no-pager -l
sudo systemctl status fstech-ui.service --no-pager -l
sudo systemctl status nginx.service --no-pager -l

sudo journalctl -u fstech-api.service -n 300 --no-pager -l
sudo journalctl -u fstech-ui.service -n 300 --no-pager -l
sudo journalctl -u nginx.service -n 100 --no-pager -l

sudo ss -lntp
curl --fail http://127.0.0.1:8000/health
curl --fail http://127.0.0.1:3000/
curl --fail http://127.0.0.1/health
~~~

Do not display `/etc/fstech.env` because it contains secrets.

## Applying Application Updates

Upload the new stack ZIP, update the existing Resource Manager stack, run Plan, and then run Apply. Terraform versions the runtime Object Storage object and replaces the disposable application VM whenever that bundle changes.

Cloud-init repeats the installation and database/agent reconciliation against the existing ADB. Seed loading and ORDS creation are idempotent.

After Apply, wait for `bootstrap_health_url` to report readiness before using `application_url`. Replacing the VM changes its public IP unless a reserved IP or load balancer is added outside this demo stack.

## Security and Production Notes

* Generated database credentials are marked sensitive by their resources but remain in Terraform state. Store state in OCI Resource Manager or another protected backend.
* Using `ADMIN` for application tables and public ORDS routes provides a zero-touch deployment, but it has a larger security blast radius than a dedicated least-privilege schema.
* Port 80 is public so the demo is immediately reachable. Add TLS, a load balancer or WAF, and authentication before production use.
* The demo ORDS routes are public. Add ORDS OAuth or roles before exposing customer or order data in production.
* Destroying the stack deletes the database and seeded data unless OCI deletion protection or backups are added first.

# Clean-Up

1. Navigate to Oracle Resource Manager.
2. Select the deployed stack.
3. Click Destroy.

Destroying the stack removes the created compartments and resources, including the Autonomous Database and seeded data, unless protection or backups are added outside this demo stack.
