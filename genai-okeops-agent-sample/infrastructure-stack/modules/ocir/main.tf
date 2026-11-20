# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_artifacts_container_repository" "this" {
  compartment_id = var.compartment_ocid
  display_name    = var.display_name
  is_public       = var.is_public
  is_immutable    = var.is_immutable
}
