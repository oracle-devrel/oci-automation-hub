# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "vcn_id" {
  description = "OCID of the VCN used by the stack (either newly created or supplied)."
  value       = local.vcn_id
}

output "private_subnet_id" {
  description = "OCID of the private subnet hosting BDS / Data Flow."
  value       = local.private_subnet_id
}

output "public_subnet_id" {
  description = "OCID of the public subnet."
  value       = local.public_subnet_id
}

output "bds_cluster_id" {
  description = "OCID of the BDS (Hadoop) cluster, if deployed."
  value       = var.deploy_bds ? oci_bds_bds_instance.this[0].id : null
}

output "bds_cluster_state" {
  description = "Lifecycle state of the BDS cluster."
  value       = var.deploy_bds ? oci_bds_bds_instance.this[0].state : null
}

output "bds_master_node_ips" {
  description = "Private IPs of the BDS master nodes."
  value = var.deploy_bds ? [
    for n in oci_bds_bds_instance.this[0].nodes :
    n.ip_address if n.node_type == "MASTER"
  ] : []
}

output "bds_utility_node_ips" {
  description = "Private IPs of the BDS utility nodes (Ambari / Cloudera Manager / Hue)."
  value = var.deploy_bds ? [
    for n in oci_bds_bds_instance.this[0].nodes :
    n.ip_address if n.node_type == "UTILITY"
  ] : []
}

output "dataflow_application_ids" {
  description = "OCIDs of the Data Flow applications, keyed by name."
  value = {
    for k, v in oci_dataflow_application.this : k => v.id
  }
}

output "dataflow_pool_id" {
  description = "OCID of the Data Flow warm pool, if created."
  value       = var.deploy_dataflow && var.dataflow_create_pool ? oci_dataflow_pool.this[0].id : null
}

output "logs_bucket_name" {
  description = "Name of the Data Flow logs bucket, if created."
  value       = var.deploy_dataflow && var.dataflow_create_logs_bucket ? oci_objectstorage_bucket.logs[0].name : null
}

output "warehouse_bucket_name" {
  description = "Name of the Data Flow warehouse bucket, if created."
  value       = var.deploy_dataflow && var.dataflow_create_warehouse_bucket ? oci_objectstorage_bucket.warehouse[0].name : null
}

output "scripts_bucket_name" {
  description = "Name of the Data Flow scripts bucket, if created."
  value       = var.deploy_dataflow && var.dataflow_create_scripts_bucket ? oci_objectstorage_bucket.scripts[0].name : null
}

output "scripts_bucket_uri" {
  description = "Object Storage URI prefix where Spark scripts live."
  value       = local.scripts_bucket_uri
}

output "operator_instance_id" {
  description = "OCID of the operator VM, if deployed."
  value       = var.deploy_operator ? oci_core_instance.operator[0].id : null
}

output "operator_private_ip" {
  description = "Private IP of the operator VM."
  value       = var.deploy_operator ? oci_core_instance.operator[0].private_ip : null
}

output "bastion_id" {
  description = "OCID of the OCI Bastion, if created."
  value       = var.deploy_operator && var.create_bastion ? oci_bastion_bastion.operator[0].id : null
}

output "bastion_name" {
  description = "Name of the OCI Bastion, if created."
  value       = var.deploy_operator && var.create_bastion ? oci_bastion_bastion.operator[0].name : null
}

output "operator_bastion_session_hint" {
  description = "Copy-paste command to open a Managed-SSH bastion session to the operator VM."
  value = var.deploy_operator && var.create_bastion ? join(" ", [
    "oci bastion session create-managed-ssh",
    "--bastion-id", oci_bastion_bastion.operator[0].id,
    "--target-resource-id", oci_core_instance.operator[0].id,
    "--target-os-username", "opc",
    "--target-private-ip", oci_core_instance.operator[0].private_ip,
    "--ssh-public-key-file", "~/.ssh/id_rsa.pub",
    "--session-ttl", tostring(var.bastion_max_session_ttl_seconds),
    "--display-name", "operator-session",
    "--wait-for-state", "SUCCEEDED",
  ]) : null
}
