# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "vcn_id" {
  value = oci_core_vcn.sql.id
}

output "subnet_ids" {
  value = {
    dc   = oci_core_subnet.dc.id
    sql1 = oci_core_subnet.sql1.id
    sql2 = oci_core_subnet.sql2.id
  }
}

output "availability_domains" {
  value = {
    dc   = local.selected_dc_availability_domain
    sql1 = local.selected_sql1_availability_domain
    sql2 = local.selected_sql2_availability_domain
  }
}

output "rdp_public_ips" {
  value = {
    dc   = oci_core_instance.dc.public_ip
    sql1 = oci_core_instance.sql1.public_ip
    sql2 = oci_core_instance.sql2.public_ip
  }
}

output "primary_private_ips" {
  value = {
    dc   = oci_core_instance.dc.private_ip
    sql1 = oci_core_instance.sql1.private_ip
    sql2 = oci_core_instance.sql2.private_ip
  }
}

output "secondary_private_ips" {
  value = {
    sql1_wsfc      = oci_core_private_ip.sql1_wsfc.ip_address
    sql2_wsfc      = oci_core_private_ip.sql2_wsfc.ip_address
    sql1_agdemodb1 = oci_core_private_ip.sql1_agdemodb1.ip_address
    sql2_agdemodb1 = oci_core_private_ip.sql2_agdemodb1.ip_address
    sql1_agdemodb2 = oci_core_private_ip.sql1_agdemodb2.ip_address
    sql2_agdemodb2 = oci_core_private_ip.sql2_agdemodb2.ip_address
  }
}

output "sql_data_volume_ids" {
  value = {
    sql1 = oci_core_volume.sql1_data.id
    sql2 = oci_core_volume.sql2_data.id
  }
}

output "post_provisioning_notes" {
  value = join(" ", [
    "Terraform apply completion means OCI instances, VNICs, and IPs were created; Windows first-boot automation continues afterward.",
    "Wait at least 10-15 minutes before testing, and on a fresh deployment allow the DC promotion cycle to finish first (often 20-25 minutes).",
    "Verify DOMAIN_READY.txt on DC-VM, WINDOWS_BOOTSTRAP_READY.txt on both SQL nodes, WSFC_READY.txt on SQL1, and TASK_5_5_LISTENER_READY.txt on both SQL nodes before using the RDP IPs or testing AOAG.",
    "DC-VM first-boot user_data configures ${var.domain_name}, creates ${var.domain_admin_user}, creates ${var.sql_service_account_user}, and creates \\\\DC-VM.${var.domain_name}\\${var.wsfc_witness_share_name}.",
    "SQL1/SQL2 first-boot user_data joins the domain, installs SQL Server/SSMS when enabled, prepares WSFC/Always On, creates the file-share witness, restores ${var.aoag_database_name} with NORECOVERY on SQL2, creates ${var.aoag_availability_group_name}, waits for synchronization, and configures the native ${var.aoag_listener_name} listener on port ${var.aoag_listener_port} with ${var.aoag_listener_ip_sql1} and ${var.aoag_listener_ip_sql2} when auto_configure_wsfc is true.",
    "The next manual step is listener connectivity and failover validation."
  ])
}

output "automation_artifact_bucket" {
  value = oci_objectstorage_bucket.automation.name
}
