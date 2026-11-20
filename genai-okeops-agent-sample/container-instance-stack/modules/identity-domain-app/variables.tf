# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "identity_domain_ocid" {
  description = "OCI Identity Domain OCID, for example ocid1.identity.oc1..aaaaaaaamjlz5jgh7uspm7h6cppdgrmlj76r7232737dsom4flwq2m4w723a."
  type        = string
}

variable "app_base_url" {
  description = "Public base URL for the application. The module registers /auth/callback as the redirect URI."
  type        = string
}

variable "app_name" {
  description = "Display name and base resource name for the OCI Identity Domain confidential application."
  type        = string
}
