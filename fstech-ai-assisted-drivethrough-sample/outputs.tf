# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "application_url" {
  description = "Public Drive-Thru web application URL. Allow 10-20 minutes for cloud-init."
  value       = "http://${oci_core_instance.app.public_ip}"
}

output "application_public_ip" {
  value = oci_core_instance.app.public_ip
}

output "network_configuration" {
  description = "VCN and subnet selected for the application VM."
  value = {
    mode      = local.selected_network_mode
    vcn_id    = local.selected_vcn_id
    subnet_id = local.selected_subnet_id
    nsg_id    = oci_core_network_security_group.app.id
  }
}

output "detected_home_region" {
  description = "Tenancy home region discovered from OCI region subscriptions."
  value       = local.home_region
}

output "created_compartments" {
  description = "Child compartments created beneath the selected parent compartment."
  value = {
    for layer, compartment in oci_identity_compartment.application_layers :
    layer => {
      name = compartment.name
      id   = compartment.id
    }
  }
}

output "genai_agent_id" {
  description = "New or reused Agent OCID."
  value       = local.genai_agent_id
}

output "genai_agent_endpoint_id" {
  value = local.genai_agent_endpoint_id
}

output "genai_function_tools" {
  description = "Function tools created directly by Terraform for the new or reused Agent."
  value = merge(
    { for tool in module.tool_vision : tool.name => tool.id },
    { for tool in module.tool_get_weather : tool.name => tool.id },
    { for tool in module.tool_search_offers : tool.name => tool.id },
    { for tool in module.tool_get_order_history : tool.name => tool.id },
    { for tool in module.tool_get_orders : tool.name => tool.id },
    { for tool in module.tool_insert_order : tool.name => tool.id },
  )
}

output "bootstrap_health_url" {
  description = "Returns verified database row counts after first-boot initialization completes."
  value       = "http://${oci_core_instance.app.public_ip}/health"
}

output "autonomous_database_id" {
  value = oci_database_autonomous_database.app.id
}

output "ords_api_root" {
  value = local.ords_root
}

output "ords_rest_apis" {
  description = "ADMIN-owned ORDS endpoints created automatically during application bootstrap."
  value = {
    insert_order = {
      method = "POST"
      url    = "${local.ords_root}/insert_order"
    }
    search_offers = {
      method = "GET"
      url    = "${local.ords_root}/search_offers"
    }
    get_order_history = {
      method = "GET"
      url    = "${local.ords_root}/get_order_history"
    }
    get_orders = {
      method = "GET"
      url    = "${local.ords_root}/get_orders"
    }
  }
}

output "database_application_schema" {
  description = "Schema that owns ORDER_DETAILS, OFFERS, and the ORDS drive_thru module."
  value       = "ADMIN"
}

output "database_verification_sql" {
  description = "Run as ADMIN in Database Actions SQL to verify the application schema and seed counts."
  value       = "SELECT (SELECT COUNT(*) FROM ADMIN.ORDER_DETAILS) AS ORDER_ROWS, (SELECT COUNT(*) FROM ADMIN.OFFERS) AS OFFER_ROWS FROM DUAL"
}

output "speech_bucket" {
  value = oci_objectstorage_bucket.app.name
}

output "speech_bucket_id" {
  value = oci_objectstorage_bucket.app.id
}

output "runtime_dynamic_group_name" {
  description = "Instance-principal dynamic group created for the application VM."
  value       = oci_identity_dynamic_group.app.name
}

output "runtime_iam_policy_name" {
  description = "Runtime policy granting access to GenAI Agents, Vision, Speech, and Object Storage."
  value       = oci_identity_policy.app.name
}

output "bootstrap_status_command" {
  value = var.ssh_public_key == "" ? "Provide ssh_public_key to enable SSH diagnostics." : "ssh opc@${oci_core_instance.app.public_ip} 'sudo cloud-init status --wait && sudo systemctl status fstech-api fstech-ui nginx'"
}
