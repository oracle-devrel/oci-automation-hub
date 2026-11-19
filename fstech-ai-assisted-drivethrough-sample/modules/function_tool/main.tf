# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_generative_ai_agent_tool" "this" {
  agent_id       = var.agent_id
  compartment_id = var.compartment_id
  display_name   = var.name
  description    = var.description
  freeform_tags = merge(var.freeform_tags, {
    "fstech-managed-by" = "terraform"
  })

  tool_config {
    tool_config_type = "FUNCTION_CALLING_TOOL_CONFIG"

    function {
      name        = var.name
      description = var.description
      parameters  = var.parameters
    }
  }
}

# OCI Agents updates the parent Agent asynchronously after a tool work request
# succeeds. A short quiet period prevents the next serialized tool from racing
# that control-plane propagation.
resource "time_sleep" "after_create" {
  depends_on      = [oci_generative_ai_agent_tool.this]
  create_duration = "10s"
}
