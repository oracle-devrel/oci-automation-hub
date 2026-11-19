# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Reconcile Terraform-owned OCI Agent tools before starting the web API."""

from __future__ import annotations

import os
import time
from collections import defaultdict

import oci


EXPECTED_TOOL_NAMES = {
    "get_order_history",
    "get_orders",
    "get_weather",
    "insert_order",
    "search_offers",
    "vision_extract_registration_number",
}
MANAGED_TAG = "fstech-managed-by"


def build_client() -> oci.generative_ai_agent.GenerativeAiAgentClient:
    region = os.environ["OCI_REGION"]
    auth_type = os.getenv("AUTH_TYPE", "instance_principal").lower()
    endpoint = f"https://agent.generativeai.{region}.oci.oraclecloud.com"

    if auth_type in {"instance_principal", "instance_principals"}:
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        return oci.generative_ai_agent.GenerativeAiAgentClient(
            {"region": region}, signer=signer, service_endpoint=endpoint
        )

    config = oci.config.from_file(
        os.path.expanduser(os.getenv("OCI_CONFIG_FILE", "~/.oci/config")),
        os.getenv("OCI_PROFILE", "DEFAULT"),
    )
    return oci.generative_ai_agent.GenerativeAiAgentClient(
        config, service_endpoint=endpoint
    )


def tool_name(tool) -> str:
    function = getattr(getattr(tool, "tool_config", None), "function", None)
    return (getattr(function, "name", None) or tool.display_name or "").strip()


def is_terraform_managed(tool) -> bool:
    return (getattr(tool, "freeform_tags", None) or {}).get(MANAGED_TAG) == "terraform"


def active_tools(client, compartment_id: str, agent_id: str):
    response = oci.pagination.list_call_get_all_results(
        client.list_tools,
        compartment_id=compartment_id,
        agent_id=agent_id,
        lifecycle_state="ACTIVE",
    )
    # Depending on the OCI Python SDK/service model version, pagination returns
    # either a plain list or a collection model whose payload is in `.items`.
    data = response.data
    if isinstance(data, list):
        return data
    return list(getattr(data, "items", []) or [])


def main() -> None:
    endpoint_id = os.environ["SUPERVISOR_ENDPOINT"]
    client = build_client()
    endpoint = client.get_agent_endpoint(endpoint_id).data

    grouped = defaultdict(list)
    for remote_tool in active_tools(client, endpoint.compartment_id, endpoint.agent_id):
        name = tool_name(remote_tool)
        if name in EXPECTED_TOOL_NAMES:
            grouped[name].append(remote_tool)

    missing = EXPECTED_TOOL_NAMES.difference(grouped)
    if missing:
        raise RuntimeError(f"Agent is missing Terraform tools: {sorted(missing)}")

    duplicates_deleted = 0
    for name in sorted(EXPECTED_TOOL_NAMES):
        tools = grouped[name]
        managed = [candidate for candidate in tools if is_terraform_managed(candidate)]
        if len(managed) != 1:
            raise RuntimeError(
                f"Expected exactly one Terraform-managed {name} tool, found {len(managed)}"
            )

        keep = managed[0]
        for duplicate in tools:
            if duplicate.id == keep.id:
                continue
            print(f"Deleting duplicate OCI Agent tool {name}: {duplicate.id}", flush=True)
            client.delete_tool(duplicate.id)
            duplicates_deleted += 1
            time.sleep(12)

    remaining = active_tools(client, endpoint.compartment_id, endpoint.agent_id)
    counts = defaultdict(int)
    for remote_tool in remaining:
        name = tool_name(remote_tool)
        if name in EXPECTED_TOOL_NAMES:
            counts[name] += 1

    invalid = {name: counts[name] for name in EXPECTED_TOOL_NAMES if counts[name] != 1}
    if invalid:
        raise RuntimeError(f"Agent tool reconciliation is still incomplete: {invalid}")

    print(
        f"OCI Agent tools are ready: 6 unique Terraform-managed tools; "
        f"removed {duplicates_deleted} duplicate(s).",
        flush=True,
    )


if __name__ == "__main__":
    main()
