# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  common_agent_plugins = [
    "Compute Instance Run Command",
    "Compute Instance Monitoring",
    "Management Agent",
    "Fleet Application Management Service",
    "Cloud Guard Workload Protection"
  ]

  effective_domain_admin_password  = var.domain_admin_password
  effective_windows_admin_password = var.windows_admin_password != "" ? var.windows_admin_password : local.effective_domain_admin_password
  effective_sql_service_password   = var.sql_service_account_password != "" ? var.sql_service_account_password : local.effective_domain_admin_password
  wsfc_primary_node                = "SQL1"
  wsfc_cluster_nodes               = "SQL1,SQL2"
  wsfc_cluster_static_addresses    = join(",", [var.wsfc_cluster_ip_sql1, var.wsfc_cluster_ip_sql2])
  aoag_listener_ips                = join(",", [var.aoag_listener_ip_sql1, var.aoag_listener_ip_sql2])
  wsfc_witness_share               = "\\\\DC-VM.${var.domain_name}\\${var.wsfc_witness_share_name}"

  # Cloudbase-init identifies #ps1_sysnative from the first rendered user-data line.
  # Keep that directive outside the UPL-headed template source.
  dc_user_data = var.auto_configure_domain_controller ? base64encode(join("\r\n", [
    "#ps1_sysnative",
    templatefile("${path.module}/templates/dc-user-data.ps1.tftpl", {
      script_body_gzip_base64      = base64gzip(file("${path.module}/scripts/dc/01-configure-domain-controller.ps1"))
      domain_name                  = var.domain_name
      domain_netbios_name          = var.domain_netbios_name
      domain_admin_user            = var.domain_admin_user
      sql_service_account_user     = var.sql_service_account_user
      local_admin_user             = var.local_admin_user
      target_computer_name         = "DC-VM"
      dc_private_ip                = var.dc_private_ip
      domain_admin_password        = replace(local.effective_domain_admin_password, "'", "''")
      sql_service_account_password = replace(local.effective_sql_service_password, "'", "''")
      windows_admin_password       = replace(local.effective_windows_admin_password, "'", "''")
      witness_path                 = var.wsfc_witness_path
      witness_share_name           = var.wsfc_witness_share_name
    }),
  ])) : null

  sql1_user_data = var.auto_configure_windows_nodes ? base64encode(join("\r\n", [
    "#ps1_sysnative",
    templatefile("${path.module}/templates/windows-node-user-data.ps1.tftpl", {
      sql_script_url                = local.automation_object_urls.sql
      wsfc_script_url               = local.automation_object_urls.wsfc
      sample_script_url             = local.automation_object_urls.sample
      ag_script_url                 = local.automation_object_urls.ag
      safe_failover_script_url      = local.automation_object_urls.safe_failover
      reconcile_script_url          = local.automation_object_urls.reconcile
      domain_name                   = var.domain_name
      domain_netbios_name           = var.domain_netbios_name
      domain_admin_user             = var.domain_admin_user
      domain_admin_password         = replace(local.effective_domain_admin_password, "'", "''")
      sql_service_account_user      = var.sql_service_account_user
      sql_service_account_password  = replace(local.effective_sql_service_password, "'", "''")
      auto_install_sql_server       = var.auto_install_sql_server
      install_ssms                  = var.install_ssms
      sql_server_download_url       = var.sql_server_download_url
      ssms_download_url             = var.ssms_download_url
      auto_configure_wsfc           = var.auto_configure_wsfc
      wsfc_cluster_name             = var.wsfc_cluster_name
      wsfc_primary_node             = local.wsfc_primary_node
      wsfc_cluster_nodes            = local.wsfc_cluster_nodes
      wsfc_cluster_static_addresses = local.wsfc_cluster_static_addresses
      wsfc_witness_share            = local.wsfc_witness_share
      skip_cluster_validation       = var.skip_cluster_validation
      aoag_database_name            = var.aoag_database_name
      aoag_availability_group_name  = var.aoag_availability_group_name
      aoag_listener_name            = var.aoag_listener_name
      aoag_listener_port            = var.aoag_listener_port
      aoag_listener_ips             = local.aoag_listener_ips
      hadr_endpoint_name            = var.hadr_endpoint_name
      hadr_endpoint_port            = var.hadr_endpoint_port
      sample_database_download_url  = var.sample_database_download_url
      local_admin_user              = var.local_admin_user
      windows_admin_password        = replace(local.effective_windows_admin_password, "'", "''")
      target_computer_name          = "SQL1"
      dc_private_ip                 = var.dc_private_ip
      sql_data_drive_letter         = var.sql_data_drive_letter
    }),
  ])) : null

  sql2_user_data = var.auto_configure_windows_nodes ? base64encode(join("\r\n", [
    "#ps1_sysnative",
    templatefile("${path.module}/templates/windows-node-user-data.ps1.tftpl", {
      sql_script_url                = local.automation_object_urls.sql
      wsfc_script_url               = local.automation_object_urls.wsfc
      sample_script_url             = ""
      ag_script_url                 = local.automation_object_urls.ag
      safe_failover_script_url      = local.automation_object_urls.safe_failover
      reconcile_script_url          = local.automation_object_urls.reconcile
      domain_name                   = var.domain_name
      domain_netbios_name           = var.domain_netbios_name
      domain_admin_user             = var.domain_admin_user
      domain_admin_password         = replace(local.effective_domain_admin_password, "'", "''")
      sql_service_account_user      = var.sql_service_account_user
      sql_service_account_password  = replace(local.effective_sql_service_password, "'", "''")
      auto_install_sql_server       = var.auto_install_sql_server
      install_ssms                  = var.install_ssms
      sql_server_download_url       = var.sql_server_download_url
      ssms_download_url             = var.ssms_download_url
      auto_configure_wsfc           = var.auto_configure_wsfc
      wsfc_cluster_name             = var.wsfc_cluster_name
      wsfc_primary_node             = local.wsfc_primary_node
      wsfc_cluster_nodes            = local.wsfc_cluster_nodes
      wsfc_cluster_static_addresses = local.wsfc_cluster_static_addresses
      wsfc_witness_share            = local.wsfc_witness_share
      skip_cluster_validation       = var.skip_cluster_validation
      aoag_database_name            = var.aoag_database_name
      aoag_availability_group_name  = var.aoag_availability_group_name
      aoag_listener_name            = var.aoag_listener_name
      aoag_listener_port            = var.aoag_listener_port
      aoag_listener_ips             = local.aoag_listener_ips
      hadr_endpoint_name            = var.hadr_endpoint_name
      hadr_endpoint_port            = var.hadr_endpoint_port
      sample_database_download_url  = var.sample_database_download_url
      local_admin_user              = var.local_admin_user
      windows_admin_password        = replace(local.effective_windows_admin_password, "'", "''")
      target_computer_name          = "SQL2"
      dc_private_ip                 = var.dc_private_ip
      sql_data_drive_letter         = var.sql_data_drive_letter
    }),
  ])) : null
}

resource "oci_core_instance" "dc" {
  availability_domain = local.selected_dc_availability_domain
  compartment_id      = var.compartment_id
  display_name        = "DC-VM"
  shape               = var.shape
  freeform_tags = merge(var.freeform_tags, {
    Role         = "domain-controller"
    Domain       = var.domain_name
    WitnessShare = local.wsfc_witness_share
  })

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    dynamic "plugins_config" {
      for_each = local.common_agent_plugins

      content {
        name          = plugins_config.value
        desired_state = "ENABLED"
      }
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.dc.id
    display_name     = "DC-VM"
    hostname_label   = "dc-vm"
    private_ip       = var.dc_private_ip
    assign_public_ip = true
    nsg_ids          = []
  }

  metadata = merge(
    var.auto_configure_domain_controller ? {
      user_data = local.dc_user_data
    } : {}
  )

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.windows_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  lifecycle {
    precondition {
      condition     = !var.auto_configure_domain_controller || (var.domain_admin_password != "" && local.effective_windows_admin_password != "" && local.effective_sql_service_password != "")
      error_message = "Set domain_admin_password and, when not reusing it, windows_admin_password and sql_service_account_password before enabling DC automation."
    }
  }
}

resource "oci_core_instance" "sql1" {
  depends_on = [oci_core_instance.dc]

  availability_domain = local.selected_sql1_availability_domain
  compartment_id      = var.compartment_id
  display_name        = "SQL1"
  shape               = var.shape
  freeform_tags = merge(var.freeform_tags, {
    Role   = "sql-node"
    Domain = var.domain_name
  })

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    dynamic "plugins_config" {
      for_each = local.common_agent_plugins

      content {
        name          = plugins_config.value
        desired_state = "ENABLED"
      }
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.sql1.id
    display_name     = "SQL1"
    hostname_label   = "sql1"
    private_ip       = var.sql1_private_ip
    assign_public_ip = true
    nsg_ids          = []
  }

  metadata = merge(
    var.auto_configure_windows_nodes ? {
      user_data = local.sql1_user_data
    } : {}
  )

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  shape_config {
    ocpus         = var.sql_ocpus
    memory_in_gbs = var.sql_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.windows_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  lifecycle {
    precondition {
      condition     = !var.auto_configure_windows_nodes || (var.domain_admin_password != "" && local.effective_windows_admin_password != "" && local.effective_sql_service_password != "")
      error_message = "Set domain_admin_password and, when not reusing it, windows_admin_password and sql_service_account_password before enabling SQL node automation."
    }
  }
}

resource "oci_core_instance" "sql2" {
  depends_on = [oci_core_instance.dc]

  availability_domain = local.selected_sql2_availability_domain
  compartment_id      = var.compartment_id
  display_name        = "SQL2"
  shape               = var.shape
  freeform_tags = merge(var.freeform_tags, {
    Role   = "sql-node"
    Domain = var.domain_name
  })

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    dynamic "plugins_config" {
      for_each = local.common_agent_plugins

      content {
        name          = plugins_config.value
        desired_state = "ENABLED"
      }
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.sql2.id
    display_name     = "SQL2"
    hostname_label   = "sql2"
    private_ip       = var.sql2_private_ip
    assign_public_ip = true
    nsg_ids          = []
  }

  metadata = merge(
    var.auto_configure_windows_nodes ? {
      user_data = local.sql2_user_data
    } : {}
  )

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  shape_config {
    ocpus         = var.sql_ocpus
    memory_in_gbs = var.sql_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.windows_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  lifecycle {
    precondition {
      condition     = !var.auto_configure_windows_nodes || (var.domain_admin_password != "" && local.effective_windows_admin_password != "" && local.effective_sql_service_password != "")
      error_message = "Set domain_admin_password and, when not reusing it, windows_admin_password and sql_service_account_password before enabling SQL node automation."
    }
  }
}
