# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  runtime_url = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.runtime.access_uri}"
  wallet_url  = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.wallet.access_uri}"
  ords_root   = "${trimsuffix(oci_database_autonomous_database.app.connection_urls[0].ords_url, "/")}/admin/api"

  cloud_init = templatefile("${path.module}/templates/app.cloud-init.tftpl", {
    runtime_url         = local.runtime_url
    wallet_url          = local.wallet_url
    adb_admin_password  = random_password.adb_admin.result
    adb_wallet_password = random_password.adb_wallet.result
    adb_dsn             = "${lower(local.adb_db_name)}_high"
    compartment_ocid    = oci_identity_compartment.application_layers["application"].id
    region              = var.region
    endpoint_ocid       = local.genai_agent_endpoint_id
    namespace           = data.oci_objectstorage_namespace.this.namespace
    bucket_name         = oci_objectstorage_bucket.app.name
    ords_root           = local.ords_root
    tts_region          = var.region
    tts_voice_id        = var.tts_voice_id
    vision_region       = var.region
  })
}

resource "oci_core_instance" "app" {
  compartment_id      = oci_identity_compartment.application_layers["application"].id
  availability_domain = data.oci_identity_availability_domains.available.availability_domains[0].name
  display_name        = "${var.name_prefix}-drive-thru-app"
  shape               = var.vm_shape
  freeform_tags       = var.freeform_tags

  shape_config {
    ocpus         = var.vm_ocpus
    memory_in_gbs = var.vm_memory_gbs
  }

  create_vnic_details {
    subnet_id        = local.selected_subnet_id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.app.id]
    hostname_label   = "drivethru"
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.oracle_linux.images[0].id
  }

  metadata = merge(
    { user_data = base64encode(local.cloud_init) },
    var.ssh_public_key == "" ? {} : { ssh_authorized_keys = var.ssh_public_key }
  )

  lifecycle {
    # cloud-init only runs on first boot. Recreate the disposable application
    # VM whenever the versioned runtime bundle changes so stack updates apply
    # database migrations, seed verification, and application fixes.
    replace_triggered_by = [oci_objectstorage_object.runtime]

    precondition {
      condition     = length(data.oci_core_images.oracle_linux.images) > 0
      error_message = "No Oracle Linux 9 image supports the selected VM shape in this region."
    }
    precondition {
      condition = var.create_genai_agent || (
        length(trimspace(var.existing_agent_id)) > 0 &&
        length(trimspace(var.existing_agent_endpoint_id)) > 0 &&
        length(trimspace(var.existing_agent_compartment_ocid)) > 0
      )
      error_message = "When create_genai_agent is false, provide existing_agent_id, existing_agent_endpoint_id, and existing_agent_compartment_ocid."
    }
    precondition {
      condition = !var.use_existing_network || (
        data.oci_core_subnet.existing[0].vcn_id == var.existing_vcn_id &&
        !data.oci_core_subnet.existing[0].prohibit_public_ip_on_vnic
      )
      error_message = "The selected existing subnet must belong to the selected VCN and permit public IP addresses. It must also route 0.0.0.0/0 to an Internet Gateway."
    }
  }

  depends_on = [
    oci_objectstorage_object.runtime,
    oci_objectstorage_object.wallet,
    oci_generative_ai_agent_agent_endpoint.drive_thru,
    module.tool_insert_order,
    time_sleep.runtime_iam_ready,
    terraform_data.network_inputs,
  ]
}
