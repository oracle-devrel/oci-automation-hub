# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_providers {
    oci = {
      source                = "hashicorp/oci"
      version               = "7.25.0"
      configuration_aliases = [oci.requestor, oci.acceptor]
    }
  }
}

resource "oci_core_remote_peering_connection" "requestor" {
  count            = var.requestor_region == var.acceptor_region ? 0 : 1
  provider         = oci.requestor
  compartment_id   = var.compartment_id
  drg_id           = var.drg_ids[var.requestor_params.drg_name]
  display_name     = "remotePeeringConnectionRequestor"
  peer_id          = oci_core_remote_peering_connection.acceptor[0].id
  peer_region_name = var.acceptor_region
}

resource "oci_core_remote_peering_connection" "acceptor" {
  count          = var.requestor_region == var.acceptor_region ? 0 : 1
  provider       = oci.acceptor
  compartment_id = var.compartment_id
  drg_id         = var.drg_ids[var.acceptor_params.drg_name]
  display_name   = "remotePeeringConnectionAcceptor"
}
