# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_providers {
    oci = {
      source  = "hashicorp/oci"
      version = "7.25.0"
    }
  }
}

locals {
  linux_boot_volumes  = [for instance in var.instance_params : instance.boot_volume_size >= 50 ? null : file(format("\n\nERROR: The boot volume size for linux instance %s is less than 50GB which is not permitted. Please add a boot volume size of 50GB or more", instance.hostname))]
  linux_block_volumes = [for block in var.bv_params : block.bv_size >= 50 && block.bv_size <= 32768 ? null : file(format("\n\nERROR: Block volume size %s for block volume %s should be between 50GB and 32768GB", block.bv_size, block.display_name))]
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

locals {
  block_volumes_templates = {
    for k, v in var.instance_params :
    k => templatefile(
      "${path.module}/../../userdata/linux_mount.sh",
      {
        length               = length(split(" ", v.device_disk_mappings)) - 1
        device_disk_mappings = v.device_disk_mappings
        block_vol_att_type   = v.block_vol_att_type
      }
    )
  }
}


data "cloudinit_config" "config" {
  for_each      = var.instance_params
  gzip          = false
  base64_encode = true

  part {
    filename     = "cloudinit.sh"
    content_type = "text/x-shellscript"
    content      = local.block_volumes_templates[each.key]
  }
}


resource "oci_core_instance" "this" {
  for_each                            = var.instance_params
  availability_domain                 = data.oci_identity_availability_domains.ads.availability_domains[each.value.ad - 1].name
  compartment_id                      = var.compartment_id
  shape                               = each.value.shape
  display_name                        = each.value.hostname
  preserve_boot_volume                = each.value.preserve_boot_volume
  freeform_tags                       = each.value.freeform_tags
  is_pv_encryption_in_transit_enabled = each.value.encrypt_in_transit
  fault_domain                        = null # TEMP # format("FAULT-DOMAIN-%s", each.value.fd)

  agent_config {
    is_management_disabled = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Block Volume Management"
    }
  }

    instance_options {
      are_legacy_imds_endpoints_disabled = each.value.are_legacy_imds_endpoints_disabled
    }

  create_vnic_details {
    assign_public_ip = each.value.assign_public_ip
    subnet_id        = var.subnet_ids[each.value.subnet_name]
    hostname_label   = each.value.hostname
    nsg_ids          = [for nsg in each.value.nsgs: var.nsgs[nsg]]
  }

  source_details {
    boot_volume_size_in_gbs = each.value.boot_volume_size
    source_type             = "image"
    source_id               = var.linux_images[var.region][each.value.image_version]
    kms_key_id              = length(var.kms_key_ids) == 0 || each.value.kms_key_name == "" ? "" : var.kms_key_ids[each.value.kms_key_name]
    boot_volume_vpus_per_gb = 120 ### TESTING
  }

  dynamic "shape_config" {
    for_each = length(regexall("^*.Flex", each.value.shape)) > 0 ? [1] : []
    content {
      memory_in_gbs             = each.value.memory_in_gbs
      ocpus                     = each.value.ocpus
      baseline_ocpu_utilization = each.value.baseline_ocpu_utilization
    }
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = data.cloudinit_config.config[each.value.hostname].rendered
  }
}

resource "oci_core_volume" "block" {
  for_each            = var.bv_params
  availability_domain = oci_core_instance.this[each.value.instance_name].availability_domain
  compartment_id      = oci_core_instance.this[each.value.instance_name].compartment_id
  display_name        = each.value.display_name
  size_in_gbs         = each.value.bv_size
  freeform_tags       = each.value.freeform_tags
  # autotune_policies {
  #     autotune_type = "PERFORMANCE_BASED"

  #     max_vpus_per_gb = 120
  # }
  vpus_per_gb         = each.value.vpus_per_gb
  kms_key_id          = length(var.kms_key_ids) == 0 || each.value.kms_key_name == "" ? "" : var.kms_key_ids[each.value.kms_key_name]
}

resource "oci_core_volume_attachment" "attachment" {
  for_each                            = var.bv_params
  attachment_type                     = var.instance_params[each.value.instance_name].block_vol_att_type
  instance_id                         = oci_core_instance.this[each.value.instance_name].id
  volume_id                           = oci_core_volume.block[each.value.display_name].id
  device                              = each.value.device_name
  is_pv_encryption_in_transit_enabled = var.instance_params[each.value.instance_name].block_vol_att_type == "paravirtualized" ? each.value.encrypt_in_transit : false
}



resource "null_resource" "passwordless_master" {
  depends_on = [ oci_core_instance.this ]
  for_each   = { for key, instance in var.instance_params: key => instance if instance.freeform_tags["role"] == "bastion" }

  provisioner "local-exec" {
    command = "sleep 100; scp -o StrictHostKeyChecking=no -i ${path.root}/id_rsa ${path.root}/id_rsa opc@${oci_core_instance.this[each.key].public_ip}:/home/opc/.ssh/id_rsa"
  }
}
