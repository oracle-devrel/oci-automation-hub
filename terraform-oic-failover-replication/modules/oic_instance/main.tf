terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_integration_integration_instance" "this" {
  compartment_id            = var.compartment_id
  domain_id                 = var.domain_id
  display_name              = var.display_name
  integration_instance_type = var.integration_instance_type
  shape                     = var.shape
  is_byol                   = var.is_byol
  message_packs             = var.message_packs
  defined_tags              = var.defined_tags
  freeform_tags             = var.freeform_tags
}
