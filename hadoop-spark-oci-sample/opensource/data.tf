# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Data sources
###############################################################################

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Region subscriptions - used to find the tenancy home region, where global IAM
# writes (dynamic groups / policies) must be executed.
data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

# "All <region> Services" object - used to route private-subnet egress to the
# Oracle Services Network through the Service Gateway.
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# Kubernetes NetworkPolicy ipBlocks require numeric CIDRs; the value exposed by
# oci_core_services is an OCI service CIDR label intended for route tables. OCI
# publishes the numeric OSN ranges for each region in this canonical document.
data "http" "oci_public_ip_ranges" {
  url = "https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json"

  request_headers = {
    Accept = "application/json"
  }
}
