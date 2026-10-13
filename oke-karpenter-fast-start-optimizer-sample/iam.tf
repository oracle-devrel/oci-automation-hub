# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_identity_dynamic_group" "karpenter_nodes" {
  compartment_id = var.tenancy_ocid
  description    = "Self-managed OKE worker nodes launched by Karpenter in ${var.project_compartment_name}."
  matching_rule  = "ALL {instance.compartment.id = '${var.project_compartment_ocid}'}"
  name           = "${var.name}-karpenter-nodes"
}

resource "oci_identity_policy" "karpenter_workload" {
  compartment_id = var.parent_compartment_ocid
  description    = "Workload identity permissions for Karpenter Provider OCI."
  name           = "${var.name}-karpenter-workload"

  statements = [
    "Allow any-user to manage instance-family in compartment ${var.project_compartment_name} where all {request.principal.type = 'workload', request.principal.namespace = '${var.karpenter_namespace}', request.principal.service_account = '${var.karpenter_service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to manage volumes in compartment ${var.project_compartment_name} where all {request.principal.type = 'workload', request.principal.namespace = '${var.karpenter_namespace}', request.principal.service_account = '${var.karpenter_service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to manage volume-attachments in compartment ${var.project_compartment_name} where all {request.principal.type = 'workload', request.principal.namespace = '${var.karpenter_namespace}', request.principal.service_account = '${var.karpenter_service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to manage virtual-network-family in compartment ${var.project_compartment_name} where all {request.principal.type = 'workload', request.principal.namespace = '${var.karpenter_namespace}', request.principal.service_account = '${var.karpenter_service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to read instance-images in compartment ${var.project_compartment_name} where all {request.principal.type = 'workload', request.principal.namespace = '${var.karpenter_namespace}', request.principal.service_account = '${var.karpenter_service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}"
  ]
}

resource "oci_identity_policy" "karpenter_nodes_join" {
  compartment_id = var.parent_compartment_ocid
  description    = "Allow Karpenter-launched self-managed nodes to join the OKE cluster."
  name           = "${var.name}-karpenter-node-join"

  statements = [
    "Allow dynamic-group id ${oci_identity_dynamic_group.karpenter_nodes.id} to {CLUSTER_JOIN} in compartment ${var.project_compartment_name} where target.cluster.id = '${oci_containerengine_cluster.this.id}'"
  ]
}

resource "oci_identity_policy" "karpenter_tenancy_inspect" {
  compartment_id = var.tenancy_ocid
  description    = "Allow Karpenter workload identity to inspect compartments for OCI resource resolution."
  name           = "${var.name}-karpenter-tenancy-inspect"

  statements = [
    "Allow any-user to inspect compartments in tenancy where all {request.principal.type = 'workload', request.principal.namespace = '${var.karpenter_namespace}', request.principal.service_account = '${var.karpenter_service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}"
  ]
}
