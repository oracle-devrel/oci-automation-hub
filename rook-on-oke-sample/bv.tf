# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  # Give the volumes a stable, searchable tag so we can find them if needed
  rook_bv_freeform_tags = {
    "managed-by" = "rook-on-oke"
    "purpose"    = "rook-osd"
  }

  # Per-node device map we want to attach: name, size, vpus, and the device path we expect on the host
  osd_disks = [
    { key = "data1", size_gb = 350, vpus_per_gb = 10,  device = "/dev/oracleoci/oraclevdb", label = "export"       },
    { key = "data2", size_gb = 700, vpus_per_gb = 120, device = "/dev/oracleoci/oraclevdc", label = "export-data"  },
  ]
}

# Read the node pool so we can get the instances (worker nodes) it created
data "oci_containerengine_node_pool" "np" {
  node_pool_id = oci_containerengine_node_pool.this.id
}

# Build a map instance_id => availability_domain for convenience
locals {
  node_instances = {
    for n in data.oci_containerengine_node_pool.np.nodes :
    n.id => n.availability_domain
  }
}

# Create the two volumes per instance
resource "oci_core_volume" "rook_osd" {
  for_each = {
    for pair in flatten([
      for instance_id, ad in local.node_instances : [
        for disk in local.osd_disks : {
          key          = "${instance_id}:${disk.key}"
          instance_id  = instance_id
          availability = ad
          size_gb      = disk.size_gb
          vpus_per_gb  = disk.vpus_per_gb
        }
      ]
    ]) : pair.key => pair
  }

  compartment_id      = var.compartment_ocid
  availability_domain = each.value.availability
  display_name        = "rook-osd-${replace(each.value.instance_id, "ocid1.instance.", "")}-${each.key}"
  size_in_gbs         = each.value.size_gb
  vpus_per_gb         = each.value.vpus_per_gb

  freeform_tags = merge(local.rook_bv_freeform_tags, {
    "node-instance-id" = each.value.instance_id
  })
}

# Attach the volumes to the corresponding node instance at fixed device paths
resource "oci_core_volume_attachment" "rook_osd_attach" {
  for_each = {
    for pair in flatten([
      for instance_id, ad in local.node_instances : [
        for disk in local.osd_disks : {
          key          = "${instance_id}:${disk.key}"
          instance_id  = instance_id
          device       = disk.device
          vol_key      = "${instance_id}:${disk.key}"
        }
      ]
    ]) : pair.key => pair
  }

  attachment_type = "paravirtualized"
  instance_id     = each.value.instance_id
  volume_id       = oci_core_volume.rook_osd[each.value.vol_key].id
  device          = each.value.device

  # Make sure attachment waits until volume is ready
  depends_on = [oci_core_volume.rook_osd]
}
