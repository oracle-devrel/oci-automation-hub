# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_ocid
}

locals {
  sorted_ad_names = sort([for ad in data.oci_identity_availability_domains.available.availability_domains : ad.name])
  ad_name_by_number = {
    for idx, ad_name in local.sorted_ad_names :
    idx + 1 => ad_name
  }

  normalized_instance_params = {
    for instance_key, params in var.instance_params :
    instance_key => merge(params, {
      os_type = lower(params.os_type)
    })
  }

  normalized_bv_params = {
    for bv_key, params in var.bv_params :
    bv_key => merge(params, {
      attachment_type = lower(trimspace(try(params.attachment_type, "iscsi")))
    })
  }

  valid_bv_params = {
    for bv_key, params in local.normalized_bv_params :
    bv_key => params
    if contains(keys(local.normalized_instance_params), params.instance_key)
  }

  instance_volume_attachment_types = {
    for instance_key, params in local.normalized_instance_params :
    instance_key => distinct([
      for bv_key, bv in local.valid_bv_params :
      bv.attachment_type
      if bv.instance_key == instance_key
    ])
  }

  windows_instance_attachment_type = {
    for instance_key, params in local.normalized_instance_params :
    instance_key => length(local.instance_volume_attachment_types[instance_key]) == 0 ? "iscsi" : local.instance_volume_attachment_types[instance_key][0]
  }

  volume_ad_number = {
    for bv_key, params in local.valid_bv_params :
    bv_key => coalesce(params.ad, local.normalized_instance_params[params.instance_key].ad)
  }

  raid0_group_pairs = distinct([
    for bv_key, params in local.valid_bv_params :
    "${params.instance_key}::${trimspace(try(params.raid0_group, ""))}"
    if trimspace(try(params.raid0_group, "")) != ""
  ])

  raid0_group_member_counts = {
    for pair in local.raid0_group_pairs :
    pair => length([
      for bv_key, params in local.valid_bv_params : 1
      if "${params.instance_key}::${trimspace(try(params.raid0_group, ""))}" == pair
    ])
  }

  instance_volume_runtime = {
    for instance_key, params in local.normalized_instance_params :
    instance_key => [
      for bv_key, bv in local.valid_bv_params : {
        key             = bv_key
        volume_id       = oci_core_volume.mssql_data[bv_key].id
        size_in_gbs     = bv.bv_size
        device_name     = bv.device_name
        attachment_type = bv.attachment_type
        raid0_group     = trimspace(try(bv.raid0_group, ""))
        mount_point     = trimspace(try(bv.mount_point, ""))
        filesystem_type = lower(trimspace(try(bv.filesystem_type, "xfs")))
      }
      if bv.instance_key == instance_key
    ]
  }

  instance_user_data = {
    for instance_key, params in local.normalized_instance_params :
    instance_key => params.os_type == "windows" ? templatefile(
      local.windows_instance_attachment_type[instance_key] == "paravirtualized" ? "${path.module}/cloud-init/windows-mssql-paravirtualized-cloud-init.ps1-cloud-init.tftpl" : "${path.module}/cloud-init/windows-mssql-cloud-init.ps1-cloud-init.tftpl",
      {
        windows_mssql_sa_password_b64  = base64encode(var.windows_mssql_sa_password)
        windows_sql_instance_name      = var.windows_sql_instance_name
        windows_sql_features           = var.windows_sql_features
        windows_sql_tcp_port           = var.windows_sql_tcp_port
        windows_choco_package_name     = var.windows_choco_package_name
        windows_open_firewall          = var.windows_open_firewall
        windows_sql_collation          = var.windows_sql_collation
        windows_volume_count           = length(local.instance_volume_runtime[instance_key])
        windows_volume_config_json_b64 = base64encode(jsonencode(local.instance_volume_runtime[instance_key]))
      }
      ) : templatefile("${path.module}/cloud-init/linux-mssql-cloud-init.cloud-init.tftpl", {
        linux_timezone                 = var.linux_timezone
        linux_mssql_pid                = var.linux_mssql_pid
        linux_mssql_sa_password_b64    = base64encode(var.linux_mssql_sa_password)
        linux_sql_tcp_port             = var.linux_sql_tcp_port
        linux_install_mssql_tools      = var.linux_install_mssql_tools
        linux_open_firewall            = var.linux_open_firewall
        linux_enable_mssql_agent       = var.linux_enable_mssql_agent
        linux_mssql_configure_memory   = var.linux_mssql_configure_memory
        linux_mssql_memory_limit_mb    = var.linux_mssql_memory_limit_mb
        linux_mssql_default_data_dir   = var.linux_mssql_default_data_dir
        linux_mssql_default_log_dir    = var.linux_mssql_default_log_dir
        linux_mssql_default_backup_dir = var.linux_mssql_default_backup_dir
        linux_volume_mount_owner       = var.linux_volume_mount_owner
        linux_volume_mount_group       = var.linux_volume_mount_group
        linux_volume_mount_mode        = var.linux_volume_mount_mode
        linux_volume_config_json_b64   = base64encode(jsonencode(local.instance_volume_runtime[instance_key]))
    })
  }

  instance_metadata = {
    for instance_key, params in local.normalized_instance_params :
    instance_key => merge(
      {
        user_data = base64encode(local.instance_user_data[instance_key])
      },
      params.os_type == "linux" ? {
        ssh_authorized_keys = try(params.ssh_public_key, "")
      } : {}
    )
  }
}

resource "terraform_data" "config_validation" {
  input = true

  lifecycle {
    precondition {
      condition     = length(local.valid_bv_params) == length(var.bv_params)
      error_message = "One or more bv_params entries reference missing instance_key values."
    }

    precondition {
      condition     = alltrue([for count in values(local.raid0_group_member_counts) : count == 2])
      error_message = "Each RAID-0 group must have exactly 2 block volumes on the same instance."
    }

    precondition {
      condition = alltrue([
        for bv_key, params in local.valid_bv_params :
        contains(["iscsi", "paravirtualized"], params.attachment_type)
      ])
      error_message = "bv_params[*].attachment_type must be iscsi or paravirtualized."
    }

    precondition {
      condition = alltrue([
        for bv_key, params in local.valid_bv_params :
        local.normalized_instance_params[params.instance_key].os_type == "windows" || params.attachment_type == "iscsi"
      ])
      error_message = "Linux block volume attachments must use attachment_type = \"iscsi\"."
    }

    precondition {
      condition = alltrue([
        for instance_key, attachment_types in local.instance_volume_attachment_types :
        local.normalized_instance_params[instance_key].os_type != "windows" || length(attachment_types) <= 1
      ])
      error_message = "Do not mix iscsi and paravirtualized block volume attachments on the same Windows instance. Cloud-init is selected per instance."
    }
  }
}

resource "oci_core_instance" "mssql_compute" {
  for_each = local.normalized_instance_params

  availability_domain = lookup(local.ad_name_by_number, each.value.ad, null)
  compartment_id      = var.compartment_ocid
  display_name        = each.value.display_name
  shape               = each.value.shape
  freeform_tags       = merge(var.freeform_tags, try(each.value.freeform_tags, {}))

  lifecycle {
    precondition {
      condition     = each.value.ad >= 1 && each.value.ad <= length(local.sorted_ad_names)
      error_message = "Instance ${each.key} has ad=${each.value.ad}. Valid range is 1..${length(local.sorted_ad_names)}."
    }

    precondition {
      condition     = contains(["linux", "windows"], each.value.os_type)
      error_message = "Instance ${each.key} has unsupported os_type=${each.value.os_type}. Use linux or windows."
    }

    precondition {
      condition     = each.value.os_type != "linux" || length(trimspace(try(each.value.ssh_public_key, ""))) > 0
      error_message = "Instance ${each.key} is linux and requires ssh_public_key."
    }

  }

  create_vnic_details {
    subnet_id        = each.value.subnet_ocid
    assign_public_ip = each.value.assign_public_ip
    nsg_ids          = try(each.value.nsg_ocids, [])
    hostname_label   = each.value.hostname
    display_name     = "${each.value.display_name}-vnic"
  }

  dynamic "shape_config" {
    for_each = try(each.value.shape_config, null) == null ? [] : [each.value.shape_config]
    content {
      ocpus         = shape_config.value.ocpus
      memory_in_gbs = shape_config.value.memory_in_gbs
    }
  }

  dynamic "agent_config" {
    for_each = each.value.os_type == "linux" ? [1] : []
    content {
      are_all_plugins_disabled = false

      plugins_config {
        name          = "Block Volume Management"
        desired_state = "ENABLED"
      }
    }
  }

  source_details {
    source_type             = "image"
    source_id               = each.value.image_ocid
    boot_volume_size_in_gbs = each.value.boot_volume_size_in_gbs
  }

  metadata = local.instance_metadata[each.key]

  depends_on = [terraform_data.config_validation]
}

resource "oci_core_volume" "mssql_data" {
  for_each = local.valid_bv_params

  availability_domain = lookup(local.ad_name_by_number, local.volume_ad_number[each.key], null)
  compartment_id      = var.compartment_ocid
  display_name        = each.value.display_name
  size_in_gbs         = each.value.bv_size
  vpus_per_gb         = try(each.value.vpus_per_gb, 10)
  freeform_tags       = merge(var.freeform_tags, try(each.value.freeform_tags, {}))

  lifecycle {
    precondition {
      condition     = local.volume_ad_number[each.key] >= 1 && local.volume_ad_number[each.key] <= length(local.sorted_ad_names)
      error_message = "Block volume ${each.key} has invalid AD selection. Set bv_params.${each.key}.ad or a valid instance_params.<key>.ad."
    }

    precondition {
      condition = trimspace(try(each.value.raid0_group, "")) == "" || (
        try(local.raid0_group_member_counts["${each.value.instance_key}::${trimspace(try(each.value.raid0_group, ""))}"], 0) == 2
      )
      error_message = "RAID-0 group ${trimspace(try(each.value.raid0_group, ""))} must contain exactly 2 volumes for instance ${each.value.instance_key}."
    }
  }

  depends_on = [terraform_data.config_validation]
}

resource "oci_core_volume_attachment" "mssql_data_attach" {
  for_each = local.valid_bv_params

  attachment_type = each.value.attachment_type
  instance_id     = oci_core_instance.mssql_compute[each.value.instance_key].id
  volume_id       = oci_core_volume.mssql_data[each.key].id
  device          = each.value.attachment_type == "iscsi" && local.normalized_instance_params[each.value.instance_key].os_type == "linux" ? each.value.device_name : null
  is_read_only    = false
  is_shareable    = false

  use_chap                          = each.value.attachment_type == "iscsi" ? try(each.value.use_chap, false) : null
  is_agent_auto_iscsi_login_enabled = each.value.attachment_type == "iscsi" && local.normalized_instance_params[each.value.instance_key].os_type == "linux" ? var.enable_agent_auto_iscsi_login : null

  depends_on = [terraform_data.config_validation]
}
