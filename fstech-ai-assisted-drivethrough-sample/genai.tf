# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  genai_agent_compartment_id = var.create_genai_agent ? oci_identity_compartment.application_layers["ai"].id : var.existing_agent_compartment_ocid
  genai_agent_id             = var.create_genai_agent ? oci_generative_ai_agent_agent.drive_thru[0].id : var.existing_agent_id
  genai_agent_endpoint_id    = var.create_genai_agent ? oci_generative_ai_agent_agent_endpoint.drive_thru[0].id : var.existing_agent_endpoint_id
  manage_genai_tools         = var.create_genai_agent || length(trimspace(var.existing_agent_id)) > 0

  # Terraform is the sole owner of the remote function definitions. The VM
  # executes requested actions against ORDS, Vision, and Open-Meteo, but never
  # creates another set of remote tools.
  genai_function_tools = {
    get_order_history = {
      description = "Fetch a customer's previous orders using the vehicle registration number."
      parameters = {
        type = "object"
        properties = {
          registration_number = {
            type        = "string"
            description = "Vehicle registration or license plate number."
          }
        }
        required = ["registration_number"]
      }
    }
    get_orders = {
      description = "Retrieve the 100 most recent orders for operational lookup."
      parameters = {
        type       = "object"
        properties = {}
      }
    }
    search_offers = {
      description = "Find current restaurant offers for a known registration, or GENERAL for a new customer."
      parameters = {
        type = "object"
        properties = {
          registration_number = {
            type        = "string"
            description = "Vehicle registration number, or GENERAL when it is not known."
            default     = "GENERAL"
          }
        }
      }
    }
    get_weather = {
      description = "Get current weather conditions used for food and drink recommendations."
      parameters = {
        type       = "object"
        properties = {}
      }
    }
    insert_order = {
      description = "Store a finalized and explicitly confirmed customer order."
      parameters = {
        type = "object"
        properties = {
          registration_number = {
            type        = "string"
            description = "Vehicle registration number."
          }
          ordered_items = {
            type        = "string"
            description = "Complete itemized order."
          }
          total_cost = {
            type        = "number"
            description = "Final order total."
          }
          customer_name = {
            type        = "string"
            description = "Customer name when known."
            default     = ""
          }
          weather_details = {
            type        = "string"
            description = "Weather context used for the recommendation."
            default     = ""
          }
        }
        required = ["registration_number", "ordered_items", "total_cost"]
      }
    }
    vision_extract_registration_number = {
      description = "Extract the exact vehicle registration number from a local vehicle image using OCI Vision OCR."
      parameters = {
        type = "object"
        properties = {
          image_path = {
            type        = "string"
            description = "Local path of the uploaded vehicle image."
          }
        }
        required = ["image_path"]
      }
    }
  }
}

resource "oci_generative_ai_agent_agent" "drive_thru" {
  count = var.create_genai_agent ? 1 : 0

  compartment_id  = oci_identity_compartment.application_layers["ai"].id
  display_name    = "${var.name_prefix}-drive-thru-agent-${random_string.deployment.result}"
  description     = "Personalized drive-thru ordering agent"
  welcome_message = "Welcome to FSTech Drive-Thru. How can I help with your order?"
  freeform_tags   = var.freeform_tags

  llm_config {
    routing_llm_customization {
      instruction = file("${path.module}/agent-instructions.txt")
    }
  }
}

resource "oci_generative_ai_agent_agent_endpoint" "drive_thru" {
  count = var.create_genai_agent ? 1 : 0

  compartment_id         = oci_identity_compartment.application_layers["ai"].id
  agent_id               = oci_generative_ai_agent_agent.drive_thru[0].id
  display_name           = "${var.name_prefix}-drive-thru-endpoint-${random_string.deployment.result}"
  description            = "Runtime endpoint for the FSTech Drive-Thru application"
  should_enable_session  = true
  should_enable_trace    = true
  should_enable_citation = false
  freeform_tags          = var.freeform_tags
}

module "tool_vision" {
  count  = local.manage_genai_tools ? 1 : 0
  source = "./modules/function_tool"

  agent_id       = local.genai_agent_id
  compartment_id = local.genai_agent_compartment_id
  name           = "vision_extract_registration_number"
  description    = local.genai_function_tools.vision_extract_registration_number.description
  parameters = {
    type       = "object"
    properties = jsonencode(local.genai_function_tools.vision_extract_registration_number.parameters.properties)
    required   = jsonencode(local.genai_function_tools.vision_extract_registration_number.parameters.required)
  }
  freeform_tags = var.freeform_tags
}

module "tool_get_weather" {
  count  = local.manage_genai_tools ? 1 : 0
  source = "./modules/function_tool"

  agent_id       = local.genai_agent_id
  compartment_id = local.genai_agent_compartment_id
  name           = "get_weather"
  description    = local.genai_function_tools.get_weather.description
  parameters = {
    type       = "object"
    properties = jsonencode(local.genai_function_tools.get_weather.parameters.properties)
  }
  freeform_tags = var.freeform_tags

  depends_on = [module.tool_vision]
}

module "tool_search_offers" {
  count  = local.manage_genai_tools ? 1 : 0
  source = "./modules/function_tool"

  agent_id       = local.genai_agent_id
  compartment_id = local.genai_agent_compartment_id
  name           = "search_offers"
  description    = local.genai_function_tools.search_offers.description
  parameters = {
    type       = "object"
    properties = jsonencode(local.genai_function_tools.search_offers.parameters.properties)
  }
  freeform_tags = var.freeform_tags

  depends_on = [module.tool_get_weather]
}

module "tool_get_order_history" {
  count  = local.manage_genai_tools ? 1 : 0
  source = "./modules/function_tool"

  agent_id       = local.genai_agent_id
  compartment_id = local.genai_agent_compartment_id
  name           = "get_order_history"
  description    = local.genai_function_tools.get_order_history.description
  parameters = {
    type       = "object"
    properties = jsonencode(local.genai_function_tools.get_order_history.parameters.properties)
    required   = jsonencode(local.genai_function_tools.get_order_history.parameters.required)
  }
  freeform_tags = var.freeform_tags

  depends_on = [module.tool_search_offers]
}

module "tool_get_orders" {
  count  = local.manage_genai_tools ? 1 : 0
  source = "./modules/function_tool"

  agent_id       = local.genai_agent_id
  compartment_id = local.genai_agent_compartment_id
  name           = "get_orders"
  description    = local.genai_function_tools.get_orders.description
  parameters = {
    type       = "object"
    properties = jsonencode(local.genai_function_tools.get_orders.parameters.properties)
  }
  freeform_tags = var.freeform_tags

  depends_on = [module.tool_get_order_history]
}

module "tool_insert_order" {
  count  = local.manage_genai_tools ? 1 : 0
  source = "./modules/function_tool"

  agent_id       = local.genai_agent_id
  compartment_id = local.genai_agent_compartment_id
  name           = "insert_order"
  description    = local.genai_function_tools.insert_order.description
  parameters = {
    type       = "object"
    properties = jsonencode(local.genai_function_tools.insert_order.parameters.properties)
    required   = jsonencode(local.genai_function_tools.insert_order.parameters.required)
  }
  freeform_tags = var.freeform_tags

  depends_on = [module.tool_get_orders]
}

# Preserve the one tool that succeeded before the earlier parallel Apply
# failed. The other five work requests never created resources.
moved {
  from = oci_generative_ai_agent_tool.function["vision_extract_registration_number"]
  to   = module.tool_vision[0].oci_generative_ai_agent_tool.this
}
