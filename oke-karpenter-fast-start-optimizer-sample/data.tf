# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "oke_worker" {
  count = var.oke_worker_image_id == null ? 1 : 0

  compartment_id = var.oke_image_compartment_ocid
  display_name   = var.oke_worker_image_display_name
  shape          = var.bootstrap_node_shape
  sort_by        = "TIMECREATED"
  sort_order     = "DESC"
  state          = "AVAILABLE"
}

data "oci_containerengine_cluster_kube_config" "this" {
  cluster_id    = oci_containerengine_cluster.this.id
  endpoint      = "PUBLIC_ENDPOINT"
  token_version = "2.0.0"
  expiration    = 2592000
}
