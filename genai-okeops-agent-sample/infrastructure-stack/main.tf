# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  container_dynamic_group_matching_rule = "ALL {resource.type = 'computecontainerinstance', resource.compartment.id = '${var.compartment_ocid}'}"
}

module "app_iam_policy" {
  source = "./modules/iam-policy"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_app_iam_policy"
  description      = "${var.component_description} - IAM Policy"
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  statements = [
    "allow any-user to use stream-push in compartment id ${var.compartment_ocid} where all {request.principal.type='serviceconnector', request.principal.compartment.id='${var.compartment_ocid}'}"
  ]
}

module "container_dynamic_group" {
  source        = "./modules/dynamic-group"
  tenancy_ocid  = var.tenancy_ocid
  name          = "${var.display_name_prefix}_container_dynamic_group"
  description   = "${var.component_description} - Container Dynamic Group"
  matching_rule = local.container_dynamic_group_matching_rule
  region        = var.region
}

module "container_iam_policy" {
  source = "./modules/iam-policy"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_container_iam_policy"
  description      = "${var.component_description} - IAM Policy"
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  statements = [
    "Allow dynamic-group id ${module.container_dynamic_group.id} to read repos in compartment id ${var.compartment_ocid}",
    "ALLOW dynamic-group id ${module.container_dynamic_group.id} to manage all-resources in compartment id ${var.compartment_ocid}"
  ]
}

module "log_group" {
  source           = "./modules/log-group"
  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_log_group"
  description      = "${var.component_description} - Log Group"
  defined_tags     = try(var.tags.definedTags, null)
  freeform_tags    = try(var.tags.freeformTags, null)

}

module "stream" {
  source = "./modules/streams"

  name             = "${var.display_name_prefix}_stream"
  partitions       = 1
  compartment_ocid = var.compartment_ocid
}

module "service_connector" {
  source = "./modules/service-connector"


  compartment_ocid    = var.compartment_ocid
  display_name        = "${var.display_name_prefix}_service_connector"
  description         = "${var.component_description} - Service Connector"
  source_log_group_id = module.log_group.id
  log_id              = module.log_group.custom_log_id
  target_stream_id    = module.stream.id
}

module "genai_agent_rag" {
  source                = "./modules/genai-agent-rag"
  kb_file_path          = "${path.module}/kb-file/kb-file.pdf"
  tenancy_ocid          = var.tenancy_ocid
  compartment_ocid      = var.compartment_ocid
  display_name_prefix   = var.display_name_prefix
  component_description = var.component_description
}

module "oke" {
  source = "./modules/oke"

  compartment_ocid    = var.compartment_ocid
  name                = "${var.display_name_prefix}-oke"
  vcn_id              = var.vcn_id
  endpoint_subnet_id  = var.oke_endpoint_subnet_id
  worker_subnet_id    = var.oke_worker_subnet_id
  public_endpoint     = var.oke_public_endpoint
  kubernetes_version  = var.kubernetes_version
  availability_domain = var.availability_domain
  node_shape          = var.node_shape
  node_image_id       = var.node_image_id
  node_count          = var.node_count
  ssh_public_key      = var.ssh_public_keys
  endpoint_nsg_ids    = [oci_core_network_security_group.oke["endpoint"].id]
  worker_nsg_ids      = [oci_core_network_security_group.oke["worker"].id]
  depends_on          = [oci_core_network_security_group_security_rule.oke_ingress, oci_core_network_security_group_security_rule.oke_egress]
}

module "mcp_ocir" {
  source = "./modules/ocir"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_ocir/mcp"
  is_public        = false
  is_immutable     = false
}

module "app_ocir" {
  source = "./modules/ocir"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_ocir/app"
  is_public        = false
  is_immutable     = false
}

module "unschedulable_pods_alarm" {
  source = "./modules/alarm-definition"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_unschedulable_pods_alarm"
  stream_id        = module.stream.id
  cluster_id       = coalesce(var.cluster_id, module.oke.cluster_id)
}
