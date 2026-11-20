# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_id
}

data "oci_core_images" "bastion" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = var.bastion_os_version
  shape                    = var.bastion_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_id
}

data "oci_containerengine_cluster_option" "versions" {
  cluster_option_id              = "all"
  compartment_id                 = var.compartment_id
  should_list_all_patch_versions = true
}

data "oci_containerengine_node_pool_option" "sources" {
  node_pool_option_id            = "all"
  compartment_id                 = var.compartment_id
  node_pool_k8s_version          = var.oke_kubernetes_version
  node_pool_os_arch              = local.oke_node_arch
  should_list_all_patch_versions = true
}
