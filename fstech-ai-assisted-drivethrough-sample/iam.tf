# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# Terraform creates the workload identity and all application runtime policies.
# The Terraform caller itself must already be authorized by OCI (for a new
# tenancy, run Resource Manager as a member of the Administrators group).
resource "oci_identity_dynamic_group" "app" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}_drive_thru_instances"
  description    = "Runtime identity for the FSTech Drive-Thru application"
  # This dedicated compartment contains only the Drive-Thru runtime. Matching
  # by compartment lets IAM exist and propagate before the instance boots.
  matching_rule = "ALL {instance.compartment.id = '${oci_identity_compartment.application_layers["application"].id}'}"
  freeform_tags = var.freeform_tags
}

resource "oci_identity_policy" "app" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}_drive_thru_runtime_policy"
  description    = "Least-scope runtime access for Drive-Thru OCI AI services"
  freeform_tags  = var.freeform_tags
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to use genai-agent in compartment id ${local.genai_agent_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to use genai-agent-endpoint in compartment id ${local.genai_agent_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage genai-agent-session in compartment id ${local.genai_agent_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage genai-agent-tool in compartment id ${local.genai_agent_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to use ai-service-vision-family in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage ai-service-speech-family in compartment id ${oci_identity_compartment.application_layers["application"].id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to read buckets in compartment id ${oci_identity_compartment.application_layers["application"].id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage objects in compartment id ${oci_identity_compartment.application_layers["application"].id}",
  ]
}

resource "time_sleep" "runtime_iam_ready" {
  depends_on      = [oci_identity_policy.app]
  create_duration = "90s"
}
