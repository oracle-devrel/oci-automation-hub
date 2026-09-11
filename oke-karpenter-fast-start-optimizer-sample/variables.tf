# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "config_file_profile" {
  description = "OCI CLI config profile used by Terraform and Kubernetes exec authentication."
  type        = string
  default     = "DEFAULT"
}

variable "region" {
  description = "OCI region for the OKE optimization environment."
  type        = string
  default     = "us-ashburn-1"
}

variable "tenancy_ocid" {
  description = "Tenancy OCID."
  type        = string
}

variable "parent_compartment_ocid" {
  description = "Parent compartment OCID for IAM policies and optional project organization."
  type        = string
}

variable "parent_compartment_name" {
  description = "Parent compartment name used in IAM policy paths."
  type        = string
  default     = "terraform"
}

variable "project_compartment_ocid" {
  description = "Compartment OCID where project resources are created."
  type        = string
}

variable "project_compartment_name" {
  description = "Project compartment name used in IAM policy statements."
  type        = string
  default     = "OKEOptimization"
}

variable "name" {
  description = "Display-name prefix for OCI and Kubernetes resources."
  type        = string
  default     = "oke-optimization"
}

variable "kubernetes_version" {
  description = "OKE Kubernetes version. KPO 1.1.0 supports Kubernetes 1.35 and newer."
  type        = string
  default     = "v1.35.2"
}

variable "cluster_type" {
  description = "OKE cluster type."
  type        = string
  default     = "ENHANCED_CLUSTER"
}

variable "cni_type" {
  description = "OKE CNI. OCI_VCN_IP_NATIVE matches the VCN-native CNI pre-pull optimization in the provided cloud-init."
  type        = string
  default     = "OCI_VCN_IP_NATIVE"

  validation {
    condition     = contains(["OCI_VCN_IP_NATIVE", "FLANNEL_OVERLAY"], var.cni_type)
    error_message = "cni_type must be OCI_VCN_IP_NATIVE or FLANNEL_OVERLAY."
  }
}

variable "cluster_dns_ip" {
  description = "Cluster DNS service IP passed to optimized OKE worker bootstrap when KPO metadata does not include it."
  type        = string
  default     = "10.96.5.5"
}

variable "oke_image_compartment_ocid" {
  description = "Oracle-published OKE image compartment used for OKE worker image lookup in the selected region."
  type        = string
}

variable "oke_worker_image_display_name" {
  description = "Oracle Linux OKE worker image display name to look up when oke_worker_image_id is null."
  type        = string
  default     = "Oracle-Linux-8.10-2026.02.28-0-OKE-1.35.2-1402"
}

variable "oke_worker_image_id" {
  description = "Optional explicit OKE worker image OCID. Leave null to look up oke_worker_image_display_name in the OKE image compartment."
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "SSH public key added to bootstrap and Karpenter-launched worker nodes."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "SSH private key used by Terraform to verify the temporary image builder."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "allowed_kubernetes_api_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint. Restrict before production use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vcn_cidr" {
  description = "VCN CIDR."
  type        = string
  default     = "10.60.0.0/16"
}

variable "api_endpoint_subnet_cidr" {
  description = "Subnet CIDR for the OKE API endpoint."
  type        = string
  default     = "10.60.0.0/28"
}

variable "worker_subnet_cidr" {
  description = "Private subnet CIDR for OKE worker primary VNICs."
  type        = string
  default     = "10.60.10.0/24"
}

variable "pod_subnet_cidr" {
  description = "Private subnet CIDR for OCI VCN-native pod secondary VNICs."
  type        = string
  default     = "10.60.20.0/22"
}

variable "load_balancer_subnet_cidr" {
  description = "Public subnet CIDR for Kubernetes service load balancers."
  type        = string
  default     = "10.60.30.0/24"
}

variable "image_builder_subnet_cidr" {
  description = "Public subnet CIDR used only by the temporary optimized OKE image builder."
  type        = string
  default     = "10.60.40.0/24"
}

variable "image_builder_ssh_cidr" {
  description = "CIDR allowed to SSH to the temporary optimized OKE image builder."
  type        = string
}

variable "image_builder_shape" {
  description = "Shape for the temporary optimized OKE image builder."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "image_builder_ocpus" {
  description = "OCPUs for the temporary optimized OKE image builder."
  type        = number
  default     = 4
}

variable "image_builder_memory_in_gbs" {
  description = "Memory for the temporary optimized OKE image builder."
  type        = number
  default     = 16
}

variable "bootstrap_node_shape" {
  description = "Managed node pool shape used only to run the KPO controller."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "bootstrap_node_ocpus" {
  description = "OCPUs for the bootstrap managed node pool shape."
  type        = number
  default     = 4
}

variable "bootstrap_node_memory_in_gbs" {
  description = "Memory for the bootstrap managed node pool shape."
  type        = number
  default     = 16
}

variable "bootstrap_node_pool_size" {
  description = "Number of managed nodes kept for KPO controller capacity."
  type        = number
  default     = 1
}

variable "worker_boot_volume_size_in_gbs" {
  description = "Boot volume size for bootstrap and Karpenter workers."
  type        = number
  default     = 50
}

variable "karpenter_chart_version" {
  description = "Karpenter Provider OCI Helm chart version."
  type        = string
  default     = "1.1.0"
}

variable "karpenter_namespace" {
  description = "Namespace for the KPO controller."
  type        = string
  default     = "karpenter"
}

variable "karpenter_service_account_name" {
  description = "Kubernetes service account used by KPO workload identity."
  type        = string
  default     = "karpenter"
}

variable "karpenter_controller_replicas" {
  description = "KPO controller replicas. Default is 1 so a single bootstrap node can host the controller."
  type        = number
  default     = 1
}

variable "karpenter_nodepool_name" {
  description = "Name for the Karpenter NodePool and OCINodeClass."
  type        = string
  default     = "optimized-ol8"
}

variable "karpenter_worker_shapes" {
  description = "OCI compute shapes Karpenter may launch for optimized workers."
  type        = list(string)
  default = [
    "VM.Standard.E5.Flex"
  ]
}

variable "karpenter_shape_configs" {
  description = "Flex shape configs KPO may use for Karpenter-launched workers."
  type = list(object({
    ocpus                     = number
    memory_in_gbs             = number
    baseline_ocpu_utilization = optional(string)
  }))
  default = [
    {
      ocpus         = 4
      memory_in_gbs = 16
    }
  ]
}

variable "karpenter_node_cpu_limit" {
  description = "Karpenter NodePool CPU limit."
  type        = string
  default     = "96"
}

variable "karpenter_node_memory_limit" {
  description = "Karpenter NodePool memory limit."
  type        = string
  default     = "384Gi"
}

variable "karpenter_pod_vnic_ip_count" {
  description = "Secondary VNIC IP count for OCI VCN-native Karpenter workers."
  type        = number
  default     = 16
}

variable "prepull_images" {
  description = "Container images pulled in the background before OKE bootstrap starts."
  type        = list(string)
  default = [
    "iad.ocir.io/axoxdievda5j/oke-public-pause@sha256:6e287874898efea60adff9dc1faaee355740b192763f963fe66cf755d995cf32",
    "iad.ocir.io/id9y6mi8tcky/oke-public-vcn-native-ip-cni-plugin@sha256:916f9953b84f2788b410c45ba766901e99d9c345d37e2fc35a16c312f27e34f0",
    "iad.ocir.io/id9y6mi8tcky/oke-public-kube-proxy@sha256:175559244baa3cbee68adfc1357c18871406c7a2d49dd487d2f04e111e7931a0"
  ]
}

variable "freeform_tags" {
  description = "Freeform tags applied to OCI resources."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Project   = "OKEOptimization"
  }
}
