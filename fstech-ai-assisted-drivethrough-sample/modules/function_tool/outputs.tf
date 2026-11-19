# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "id" {
  value      = oci_generative_ai_agent_tool.this.id
  depends_on = [time_sleep.after_create]
}

output "name" {
  value = var.name
}
