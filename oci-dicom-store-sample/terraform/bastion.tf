# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_instance" "bastion" {
  availability_domain = data.oci_identity_availability_domains.available.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "${local.resource_name}-bastion"
  shape               = var.bastion_shape
  freeform_tags       = local.tags

  shape_config {
    ocpus         = var.bastion_ocpus
    memory_in_gbs = var.bastion_memory_gb
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${local.resource_name}-bastion"
    hostname_label   = "bastion"
    nsg_ids          = [local.bastion_nsg.id]
    subnet_id        = oci_core_subnet.management.id
  }

  source_details {
    source_id               = data.oci_core_images.bastion.images[0].id
    source_type             = "image"
    boot_volume_size_in_gbs = var.bastion_boot_volume_gb
    boot_volume_vpus_per_gb = 10
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = {
    ssh_authorized_keys = local.bastion_ssh_public_key
    user_data = base64encode(templatefile(
      "${path.module}/bastion/cloud-init.yaml.tftpl",
      { deployment_name = local.resource_name },
    ))
  }

  lifecycle {
    precondition {
      condition     = length(data.oci_core_images.bastion.images) > 0
      error_message = "No compatible Oracle Linux ${var.bastion_os_version} image was found for ${var.bastion_shape} in ${var.region}."
    }
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
