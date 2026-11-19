# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Outputs
###############################################################################

output "cluster_id" {
  description = "OCID of the OKE cluster."
  value       = module.oke.cluster_id
}

output "cluster_name" {
  description = "Name of the OKE cluster."
  value       = var.cluster_name
}

output "kubernetes_version" {
  description = "Kubernetes version of the cluster."
  value       = var.kubernetes_version
}

output "bastion_id" {
  description = "OCID of the OCI Bastion (for SSH to nodes / tunnelling kubectl to a private endpoint)."
  value       = oci_bastion_bastion.this.id
}

output "object_storage_bucket" {
  description = "Object Storage bucket used as the data lake."
  value       = var.deploy_object_storage ? local.bucket_name : "not deployed"
}

output "operator_private_ip" {
  description = "Private IP of the operator host (reach it via the OCI Bastion to run kubectl)."
  value       = try(module.oke.operator_private_ip, null)
}

output "operator_access" {
  description = "One command to connect to the operator: creates the Bastion session, waits, and SSHes in (host-key checks disabled for the ephemeral tunnel). Needs the oci CLI and the SSH private key matching ssh_public_key (default ~/.ssh/id_rsa). Run from the stack directory."
  value       = "./scripts/connect-operator.sh -b ${oci_bastion_bastion.this.id} -i ${try(module.oke.operator_private_ip, "<pending-until-apply>")}"
}

output "cluster_summary" {
  description = "Human-readable summary of what was deployed."
  value = join("\n", [
    "Cluster        : ${var.cluster_name} (OKE, Kubernetes ${var.kubernetes_version})",
    "API endpoint   : ${var.cluster_endpoint_is_public ? "public, NSG-locked to ${local.admin_cidr}" : "private (reach via Bastion/operator)"}",
    "Worker nodes   : ${var.node_count} x ${var.node_shape} (private subnet, no public IPs)",
    "Operator       : private VM in-VCN; installs the platform via cloud-init",
    "Namespace      : ${local.namespace}",
    "HDFS           : ${var.deploy_hdfs ? "enabled (Kerberos realm ${local.realm}, ${var.hdfs_datanode_count} DataNodes)" : "disabled"}",
    "Object Storage : ${var.deploy_object_storage ? "enabled (bucket ${local.bucket_name}, Workload Identity)" : "disabled"}",
    "Spark          : ${var.deploy_spark ? "enabled (Spark Operator, runs on Kubernetes)" : "disabled"}",
    "Images         : ${var.image_source}",
    "Security       : private nodes, NSG-locked API, Kerberos (HDFS), Pod Security (baseline), default-deny NetworkPolicies",
    "",
    "The operator installs the platform asynchronously after apply. Reach the",
    "operator via the OCI Bastion, then: kubectl -n ${local.namespace} get pods",
  ])
}

###############################################################################
# In-cluster platform
###############################################################################

output "namespace" {
  description = "Kubernetes namespace the platform runs in."
  value       = local.namespace
}

output "kdc_host" {
  description = "In-cluster DNS name of the Kerberos KDC."
  value       = var.deploy_hdfs ? local.kdc_host : "HDFS not deployed"
}

output "hdfs_url" {
  description = "HDFS default filesystem URL (fs.defaultFS)."
  value       = var.deploy_hdfs ? local.hdfs_default : "HDFS not deployed"
}

output "hadoop_user_password" {
  description = "Password for the 'hadoop@<realm>' Kerberos principal (kinit). Sensitive."
  value       = try(random_password.hadoop_user[0].result, "HDFS not deployed")
  sensitive   = true
}

output "object_storage_path" {
  description = "Object Storage path Spark should use."
  value       = var.deploy_object_storage ? "oci://${local.bucket_name}@${local.os_namespace}/" : "Object Storage not deployed"
}

output "spark_smoke_test" {
  description = "Run the SparkPi example (from the operator host) to confirm Spark-on-Kubernetes works."
  value = var.deploy_spark ? join(" ", [
    "kubectl -n ${local.namespace} get configmap spark-examples",
    "-o go-template='{{index .data \"sparkpi.yaml\"}}' | kubectl apply -f -",
  ]) : "Spark not deployed"
}
