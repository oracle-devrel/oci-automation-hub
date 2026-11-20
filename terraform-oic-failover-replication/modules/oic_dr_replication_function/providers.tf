# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.

terraform {
  required_providers {
    oci = {
      source                = "oracle/oci"
      configuration_aliases = [oci.home]
    }
  }
}
