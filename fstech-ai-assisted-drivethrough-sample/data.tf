# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_ocid
}

data "oci_identity_region_subscriptions" "tenancy" {
  tenancy_id = var.tenancy_ocid
}

data "oci_core_vcn" "existing" {
  count  = var.use_existing_network ? 1 : 0
  vcn_id = var.existing_vcn_id
}

data "oci_core_subnet" "existing" {
  count     = var.use_existing_network ? 1 : 0
  subnet_id = var.existing_subnet_id
}

data "oci_core_images" "oracle_linux" {
  compartment_id           = oci_identity_compartment.application_layers["application"].id
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.vm_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

data "archive_file" "runtime" {
  type        = "zip"
  source_dir  = "${path.module}/runtime"
  output_path = "${path.module}/fstech-runtime.zip"
}
