# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "project_compartment_id" {
  description = "OCID of the OKEOptimization project compartment."
  value       = var.project_compartment_ocid
}

output "cluster_id" {
  description = "OKE cluster OCID."
  value       = oci_containerengine_cluster.this.id
}

output "cluster_private_endpoint" {
  description = "Private Kubernetes API endpoint passed to KPO for worker bootstrap."
  value       = local.cluster_private_endpoint
}

output "cluster_public_endpoint" {
  description = "Public Kubernetes API endpoint used by Terraform providers."
  value       = oci_containerengine_cluster.this.endpoints[0].public_endpoint
}

output "worker_image_id" {
  description = "Oracle Linux OKE worker image used by the bootstrap pool and as the custom image base."
  value       = local.worker_image_id
}

output "optimized_worker_image_id" {
  description = "Custom optimized Oracle Linux OKE worker image used by Karpenter."
  value       = oci_core_image.optimized_oke_worker.id
}

output "optimized_worker_image_display_name" {
  description = "Display name for the custom optimized Oracle Linux OKE worker image."
  value       = oci_core_image.optimized_oke_worker.display_name
}

output "image_builder_instance_id" {
  description = "Temporary builder instance used to create the optimized worker image."
  value       = oci_core_instance.image_builder.id
}

output "worker_image_display_name" {
  description = "Display name looked up for the worker image when oke_worker_image_id is null."
  value       = var.oke_worker_image_id == null ? data.oci_core_images.oke_worker[0].images[0].display_name : null
}

output "karpenter_namespace" {
  description = "Namespace where KPO is installed."
  value       = var.karpenter_namespace
}

output "karpenter_nodepool_name" {
  description = "Karpenter NodePool and OCINodeClass name."
  value       = var.karpenter_nodepool_name
}
