# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "compute_instance_ids" {
  description = "Compute instance OCIDs keyed by instance key."
  value = {
    for key, instance in oci_core_instance.mssql_compute :
    key => instance.id
  }
}

output "compute_private_ips" {
  description = "Primary private IPs keyed by instance key."
  value = {
    for key, instance in oci_core_instance.mssql_compute :
    key => instance.private_ip
  }
}

output "compute_public_ips" {
  description = "Primary public IPs keyed by instance key (if assigned)."
  value = {
    for key, instance in oci_core_instance.mssql_compute :
    key => instance.public_ip
  }
}

output "compute_availability_domains" {
  description = "Resolved availability domain name keyed by instance key."
  value = {
    for key, instance in oci_core_instance.mssql_compute :
    key => instance.availability_domain
  }
}

output "block_volume_ids" {
  description = "Block volume OCIDs keyed by bv_params key."
  value = {
    for key, volume in oci_core_volume.mssql_data :
    key => volume.id
  }
}

output "block_volume_attachment_ids" {
  description = "Volume attachment OCIDs keyed by bv_params key."
  value = {
    for key, attachment in oci_core_volume_attachment.mssql_data_attach :
    key => attachment.id
  }
}

output "block_volume_attachment_details" {
  description = "Block volume attachment details keyed by bv_params key."
  value = {
    for key, attachment in oci_core_volume_attachment.mssql_data_attach :
    key => {
      attachment_type = local.valid_bv_params[key].attachment_type
      instance_id     = attachment.instance_id
      volume_id       = attachment.volume_id
      iqn             = attachment.iqn
      ipv4            = attachment.ipv4
      port            = attachment.port
      device          = attachment.device
      use_chap        = attachment.use_chap
    }
  }
}

output "block_volume_attachment_iscsi" {
  description = "iSCSI connection details keyed by bv_params key. Paravirtualized attachments are excluded."
  value = {
    for key, attachment in oci_core_volume_attachment.mssql_data_attach :
    key => {
      instance_id = attachment.instance_id
      volume_id   = attachment.volume_id
      iqn         = attachment.iqn
      ipv4        = attachment.ipv4
      port        = attachment.port
      device      = attachment.device
      use_chap    = attachment.use_chap
    }
    if local.valid_bv_params[key].attachment_type == "iscsi" && local.normalized_instance_params[local.valid_bv_params[key].instance_key].os_type == "windows"
  }
}

output "windows_iscsi_attach_commands" {
  description = "Ready-to-run Windows iSCSI attach commands keyed by bv_params key. Paravirtualized attachments are excluded."
  value = {
    for key, attachment in oci_core_volume_attachment.mssql_data_attach :
    key => join("\n", [
      "Set-Service -Name msiscsi -StartupType Automatic",
      "Start-Service msiscsi",
      "iscsicli.exe QAddTargetPortal ${attachment.ipv4}",
      "iscsicli.exe QLoginTarget ${attachment.iqn}",
      "iscsicli.exe PersistentLoginTarget ${attachment.iqn} * ${attachment.ipv4} ${coalesce(tostring(attachment.port), "3260")} * * * * * * * * * * * * * * * *",
      "Update-HostStorageCache",
      "Get-Disk",
    ])
    if local.valid_bv_params[key].attachment_type == "iscsi" && local.normalized_instance_params[local.valid_bv_params[key].instance_key].os_type == "windows"
  }
}
