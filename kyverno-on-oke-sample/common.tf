# Copyright (c) 2024, 2026 Oracle Corporation and/or its affiliates.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  state_id = coalesce(var.state_id, random_string.state_id.id)
}

resource "random_string" "state_id" {
  length  = 6
  lower   = true
  numeric = false
  special = false
  upper   = false
}