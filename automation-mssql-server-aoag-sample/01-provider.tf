# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
provider "oci" {
  region = var.region
  # Resource Manager supplies OCI authentication. A local run uses ~/.oci/config.
  config_file_profile = var.execution_environment == "local" ? var.oci_config_profile : null
}
