# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Input variables - Secure Hadoop & Spark on OKE
#
# Security posture is fixed and strict (see README.md). What is configurable is
# WHICH storage backends to deploy (HDFS, Object Storage, or both), sizing, and
# the container image source.
###############################################################################

# ---------------------------------------------------------------------------
# Resource Manager / tenancy context (auto-populated by RM)
# ---------------------------------------------------------------------------
variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy. Auto-populated by Resource Manager."
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where all resources are created."
}

variable "region" {
  type        = string
  description = "OCI region identifier. Auto-populated by Resource Manager."
}

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------
variable "cluster_name" {
  type        = string
  default     = "bigdata"
  description = "Short name used as a prefix for every resource."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.cluster_name))
    error_message = "cluster_name must start with a letter, be 2-25 chars, lowercase letters/digits/hyphens."
  }
}

variable "admin_cidr" {
  type        = string
  description = "The only network range allowed to reach the Kubernetes API endpoint and open OCI Bastion sessions. Set this to your own IP, e.g. 203.0.113.4/32."

  validation {
    condition     = can(cidrhost(trimspace(var.admin_cidr), 0))
    error_message = "admin_cidr must be a valid CIDR block."
  }
  validation {
    condition     = trimspace(var.admin_cidr) != "0.0.0.0/0"
    error_message = "admin_cidr must not be 0.0.0.0/0. Restrict access to a specific network."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key installed on the worker nodes (for break-glass access via the OCI Bastion)."

  validation {
    condition     = length(trimspace(var.ssh_public_key)) > 0
    error_message = "An SSH public key is required."
  }
}

# ---------------------------------------------------------------------------
# OKE cluster
# ---------------------------------------------------------------------------
variable "kubernetes_version" {
  type        = string
  default     = "v1.35.2"
  description = "Kubernetes version for the OKE cluster and node pool. Must be a FULL version (vMAJOR.MINOR.PATCH) that OKE publishes - a partial version like 'v1.36' has no matching worker image. Default is the latest GA version; v1.36.0 exists but is a preview release (not for production, OC1 realm only). List valid versions with: oci ce cluster-options get --cluster-option-id all"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a full version like v1.34.2 (vMAJOR.MINOR.PATCH). A partial version such as v1.36 has no matching OKE worker image."
  }
}

variable "cluster_endpoint_is_public" {
  type        = bool
  default     = true
  description = "If true, the Kubernetes API endpoint is public but locked by NSG to admin_cidr (lets Terraform deploy the workload layer in one run). If false, the endpoint is fully private and the workload layer must be applied through the Bastion."
}

# ---------------------------------------------------------------------------
# Worker node pool
# ---------------------------------------------------------------------------
variable "node_count" {
  type        = number
  default     = 3
  description = "Number of worker nodes in the node pool."

  validation {
    condition     = var.node_count >= 2 && var.node_count <= 100
    error_message = "node_count must be between 2 and 100."
  }
}

variable "node_shape" {
  type        = string
  default     = "VM.Standard.E5.Flex"
  description = "Compute shape for the worker nodes."
}

variable "node_ocpus" {
  type        = number
  default     = 4
  description = "OCPUs per worker node (flexible shapes only)."

  validation {
    condition     = var.node_ocpus >= 2 && var.node_ocpus <= 128
    error_message = "node_ocpus must be between 2 and 128."
  }
}

variable "node_memory_gbs" {
  type        = number
  default     = 64
  description = "Memory (GB) per worker node (flexible shapes only)."

  validation {
    condition     = var.node_memory_gbs >= 16 && var.node_memory_gbs <= 2048
    error_message = "node_memory_gbs must be between 16 and 2048."
  }
}

variable "node_boot_volume_gbs" {
  type        = number
  default     = 100
  description = "Boot volume size (GB) per worker node."

  validation {
    condition     = var.node_boot_volume_gbs >= 50 && var.node_boot_volume_gbs <= 32768
    error_message = "node_boot_volume_gbs must be between 50 and 32768."
  }
}

# ---------------------------------------------------------------------------
# Storage backends  (deploy either, or both)
# ---------------------------------------------------------------------------
variable "deploy_hdfs" {
  type        = bool
  default     = true
  description = "Deploy HDFS (Kerberos-secured NameNode + DataNode StatefulSets on the cluster)."
}

variable "deploy_object_storage" {
  type        = bool
  default     = true
  description = "Create an OCI Object Storage bucket and wire Spark to use it (oci:// paths) via OKE Workload Identity."
}

variable "force_destroy_bucket" {
  type        = bool
  default     = true
  description = "On `terraform destroy`, empty the data bucket (all objects AND versions) so it can be deleted - otherwise destroy fails with 409-BucketNotEmpty. Set false to protect bucket data from teardown."
}

# ---------------------------------------------------------------------------
# HDFS sizing
# ---------------------------------------------------------------------------
variable "hdfs_replication" {
  type        = number
  default     = 3
  description = "HDFS block replication factor. Automatically capped to the DataNode count."

  validation {
    condition     = var.hdfs_replication >= 1 && var.hdfs_replication <= 10
    error_message = "hdfs_replication must be between 1 and 10."
  }
}

variable "hdfs_namenode_storage_gbs" {
  type        = number
  default     = 100
  description = "Persistent volume size (GB) for the HDFS NameNode metadata."

  validation {
    condition     = var.hdfs_namenode_storage_gbs >= 50 && var.hdfs_namenode_storage_gbs <= 32768
    error_message = "hdfs_namenode_storage_gbs must be between 50 and 32768."
  }
}

variable "hdfs_datanode_count" {
  type        = number
  default     = 3
  description = "Number of HDFS DataNode replicas (StatefulSet)."

  validation {
    condition     = var.hdfs_datanode_count >= 1 && var.hdfs_datanode_count <= 100
    error_message = "hdfs_datanode_count must be between 1 and 100."
  }
}

variable "hdfs_datanode_storage_gbs" {
  type        = number
  default     = 200
  description = "Persistent volume size (GB) for each HDFS DataNode."

  validation {
    condition     = var.hdfs_datanode_storage_gbs >= 50 && var.hdfs_datanode_storage_gbs <= 32768
    error_message = "hdfs_datanode_storage_gbs must be between 50 and 32768."
  }
}

# ---------------------------------------------------------------------------
# Spark
# ---------------------------------------------------------------------------
variable "deploy_spark" {
  type        = bool
  default     = true
  description = "Deploy the Apache Spark Operator so Spark applications run natively on Kubernetes."
}

variable "spark_operator_chart_version" {
  type        = string
  default     = "1.4.6"
  description = "Version of the kubeflow spark-operator Helm chart."
}

# ---------------------------------------------------------------------------
# In-cluster storage
# ---------------------------------------------------------------------------
variable "storage_class" {
  type        = string
  default     = "oci-bv"
  description = "Kubernetes StorageClass for HDFS / KDC PersistentVolumes (oci-bv = OCI Block Volume CSI, available on OKE by default)."
}

# ---------------------------------------------------------------------------
# Kerberos
# ---------------------------------------------------------------------------
variable "kerberos_realm" {
  type        = string
  default     = "HADOOP.INTERNAL"
  description = "Kerberos realm. A KDC is deployed in-cluster when HDFS is enabled."

  validation {
    condition     = can(regex("^[A-Z][A-Z0-9.-]{2,48}$", var.kerberos_realm))
    error_message = "kerberos_realm must be uppercase letters/digits/dots/hyphens, e.g. HADOOP.INTERNAL."
  }
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------
variable "image_source" {
  type        = string
  default     = "upstream"
  description = "Where container images come from: 'upstream' (public Apache images, one-click) or 'ocir' (custom hardened images you have pushed to OCI Registry)."

  validation {
    condition     = contains(["upstream", "ocir"], var.image_source)
    error_message = "image_source must be 'upstream' or 'ocir'."
  }
}

# NOTE: OKE worker nodes run CRI-O with short-name mode = enforcing, which
# rejects unqualified image names. Always use a FULLY-QUALIFIED registry path
# (e.g. docker.io/apache/spark:3.5.3), including for image_source=ocir images.
variable "hadoop_image" {
  type        = string
  default     = "docker.io/apache/hadoop:3.3.6"
  description = "Hadoop/HDFS container image (fully-qualified). With image_source=ocir, set this to your OCIR image."
}

variable "spark_image" {
  type        = string
  default     = "docker.io/apache/spark:3.5.3"
  description = "Spark container image (fully-qualified). With image_source=ocir, set this to your OCIR image."
}

variable "kdc_image" {
  type        = string
  default     = "docker.io/library/oraclelinux:8"
  description = "Base image for the Kerberos KDC pod (fully-qualified; krb5-server is installed at startup on the upstream path). With image_source=ocir, set this to a prebuilt KDC image."
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vcn_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR block for the new VCN."

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be a valid CIDR block."
  }
}

variable "endpoint_subnet_cidr" {
  type        = string
  default     = "10.20.0.0/28"
  description = "CIDR block for the Kubernetes API endpoint subnet."

  validation {
    condition     = can(cidrhost(var.endpoint_subnet_cidr, 0))
    error_message = "endpoint_subnet_cidr must be a valid CIDR block."
  }
}

variable "nodes_subnet_cidr" {
  type        = string
  default     = "10.20.1.0/24"
  description = "CIDR block for the private worker-node subnet."

  validation {
    condition     = can(cidrhost(var.nodes_subnet_cidr, 0))
    error_message = "nodes_subnet_cidr must be a valid CIDR block."
  }
}

variable "lb_subnet_cidr" {
  type        = string
  default     = "10.20.2.0/24"
  description = "CIDR block for the private internal load-balancer subnet. OKE requires a service load-balancer subnet; this stack keeps it private and creates no public LBs."

  validation {
    condition     = can(cidrhost(var.lb_subnet_cidr, 0))
    error_message = "lb_subnet_cidr must be a valid CIDR block."
  }
}

# ---------------------------------------------------------------------------
# Software versions (used for image tags and in-cluster config)
# ---------------------------------------------------------------------------
variable "hadoop_version" {
  type        = string
  default     = "3.3.6"
  description = "Apache Hadoop version (must match the hadoop_image tag)."
}

variable "spark_version" {
  type        = string
  default     = "3.5.3"
  description = "Apache Spark version (must match the spark_image tag)."
}
