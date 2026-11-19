# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Authentication / placement
###############################################################################

variable "tenancy_ocid" {
  description = "OCID of the tenancy. Injected automatically by Resource Manager."
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment in which all resources are created."
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g. eu-frankfurt-1). Injected automatically by Resource Manager."
  type        = string
}

variable "user_ocid" {
  description = "User OCID. Only required for the CLI auth flow; leave empty for Resource Manager / instance principal."
  type        = string
  default     = ""
}

variable "fingerprint" {
  description = "API key fingerprint. Only required for the CLI auth flow."
  type        = string
  default     = ""
}

variable "private_key_path" {
  description = "Path to the API private key file. Only required for the CLI auth flow."
  type        = string
  default     = ""
}

###############################################################################
# Naming / tagging
###############################################################################

variable "resource_prefix" {
  description = "Prefix prepended to every resource display name."
  type        = string
  default     = "bigdata"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.resource_prefix))
    error_message = "Prefix must start with a letter, be 2-19 chars, lower-case letters/digits/hyphens only."
  }
}

variable "freeform_tags" {
  description = "Free-form tags applied to every resource."
  type        = map(string)
  default = {
    "stack" = "spark-hadoop-native"
  }
}

###############################################################################
# SSH access
###############################################################################

variable "ssh_public_key" {
  description = "SSH public key used for BDS node access. Required when deploy_bds = true."
  type        = string
  default     = ""
}

###############################################################################
# Network — set create_vcn = false to reuse an existing one
###############################################################################

variable "create_vcn" {
  description = "When true, a new VCN + subnets + gateways are created. When false you must supply existing_*_id variables."
  type        = bool
  default     = true
}

variable "vcn_cidr_block" {
  description = "CIDR block used when create_vcn = true."
  type        = string
  default     = "10.0.0.0/16"
}

variable "vcn_dns_label" {
  description = "DNS label for the VCN (max 15 chars, alphanumeric)."
  type        = string
  default     = "bdvcn"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet that hosts BDS / Data Flow workloads."
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (jump host / bastion / NAT egress reporting)."
  type        = string
  default     = "10.0.0.0/24"
}

variable "existing_vcn_id" {
  description = "OCID of an existing VCN to reuse. Required when create_vcn = false."
  type        = string
  default     = ""
}

variable "existing_private_subnet_id" {
  description = "OCID of an existing private subnet (BDS + Data Flow). Required when create_vcn = false."
  type        = string
  default     = ""
}

variable "existing_public_subnet_id" {
  description = "OCID of an existing public subnet. Optional when create_vcn = false."
  type        = string
  default     = ""
}

###############################################################################
# Big Data Service (Hadoop) cluster
###############################################################################

variable "deploy_bds" {
  description = "Deploy an OCI Big Data Service (Hadoop) cluster."
  type        = bool
  default     = true
}

variable "bds_oracle_network_cidr" {
  description = <<-EOT
    CIDR block for the Oracle-managed network that BDS provisions for the
    cluster. It must NOT overlap the VCN/subnet the cluster attaches to,
    otherwise CreateBdsInstance fails with "Provided CIDR block ... overlaps
    with subnet CIDR block ...". Defaults to 172.16.0.0/16, which does not
    overlap the default VCN (10.0.0.0/16). Change it only if your VCN/subnet
    already uses 172.16.0.0/16.
  EOT
  type        = string
  default     = "172.16.0.0/16"
}

variable "bds_display_name" {
  description = "Display name for the BDS cluster. Defaults to <prefix>-hadoop when empty."
  type        = string
  default     = ""
}

variable "bds_cluster_version" {
  description = "BDS cluster version. API values use underscores (ODH2_0), not dots."
  type        = string
  default     = "ODH2_0"

  validation {
    condition     = contains(["CDH5", "CDH6", "ODH0_9", "ODH1", "ODH2_0"], var.bds_cluster_version)
    error_message = "Allowed values: CDH5, CDH6, ODH0_9, ODH1, ODH2_0."
  }
}

variable "bds_cluster_profile" {
  description = "BDS cluster profile — controls which Hadoop ecosystem services are installed."
  type        = string
  default     = "HADOOP_EXTENDED"

  validation {
    condition = contains([
      "HADOOP", "HADOOP_EXTENDED", "HIVE", "SPARK",
      "HBASE", "TRINO", "KAFKA", "DATAFLOW", "DATA_SCIENCE", "AIRFLOW"
    ], var.bds_cluster_profile)
    error_message = "Invalid cluster profile."
  }
}

variable "bds_is_high_availability" {
  description = "Whether to deploy 2 master + 2 utility nodes (HA) instead of 1+1."
  type        = bool
  default     = false
}

variable "bds_is_secure" {
  description = "Enable Kerberos + Sentry/Ranger on the cluster."
  type        = bool
  default     = false
}

variable "bds_cluster_admin_password" {
  description = "Cluster admin password in plaintext (Ambari/Cloudera Manager). Required when deploy_bds = true. Must meet OCI BDS complexity: 8+ chars with at least one uppercase, lowercase, digit, and special character. The module base64-encodes it before sending to the BDS API."
  type        = string
  default     = ""
  sensitive   = true
}

# Master node
variable "bds_master_shape" {
  description = "Shape of the master nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}
variable "bds_master_ocpus" {
  description = "OCPUs per master node (flex shapes only)."
  type        = number
  default     = 4
}
variable "bds_master_memory_gbs" {
  description = "Memory per master node in GB (flex shapes only)."
  type        = number
  default     = 64
}
variable "bds_master_block_volume_gbs" {
  description = "Block volume size per master node in GB."
  type        = number
  default     = 500
}

# Utility node
variable "bds_utility_shape" {
  description = "Shape of the utility nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}
variable "bds_utility_ocpus" {
  description = "OCPUs per utility node."
  type        = number
  default     = 4
}
variable "bds_utility_memory_gbs" {
  description = "Memory per utility node in GB."
  type        = number
  default     = 64
}
variable "bds_utility_block_volume_gbs" {
  description = "Block volume size per utility node in GB."
  type        = number
  default     = 500
}

# Worker nodes
variable "bds_worker_shape" {
  description = "Shape of the worker nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}
variable "bds_worker_ocpus" {
  description = "OCPUs per worker node."
  type        = number
  default     = 8
}
variable "bds_worker_memory_gbs" {
  description = "Memory per worker node in GB."
  type        = number
  default     = 128
}
variable "bds_worker_count" {
  description = "Number of worker nodes (minimum 3)."
  type        = number
  default     = 3

  validation {
    condition     = var.bds_worker_count >= 3
    error_message = "BDS requires at least 3 worker nodes."
  }
}
variable "bds_worker_block_volume_gbs" {
  description = "Block volume size per worker node in GB."
  type        = number
  default     = 1000
}

# Compute-only worker nodes — for Spark workloads that need elastic compute
variable "bds_compute_only_worker_count" {
  description = "Number of compute-only worker nodes (no HDFS storage)."
  type        = number
  default     = 0
}
variable "bds_compute_only_worker_shape" {
  description = "Shape of compute-only worker nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}
variable "bds_compute_only_worker_ocpus" {
  description = "OCPUs per compute-only worker node."
  type        = number
  default     = 8
}
variable "bds_compute_only_worker_memory_gbs" {
  description = "Memory per compute-only worker node in GB."
  type        = number
  default     = 128
}

variable "bds_bootstrap_script_url" {
  description = "Optional Object Storage URL of a bootstrap script that customises Hadoop / Spark configs at cluster creation time."
  type        = string
  default     = ""
}

###############################################################################
# Data Flow (managed Spark) — applications are defined declaratively
###############################################################################

variable "deploy_dataflow" {
  description = "Deploy OCI Data Flow applications + pool."
  type        = bool
  default     = true
}

variable "create_iam_resources" {
  description = <<-EOT
    When true the stack creates the tenancy-level IAM resources it needs:

      * a dynamic group + policy that let Data Flow runs read/write the
        Object Storage buckets in this compartment (when deploy_dataflow), and
      * a policy that lets the Big Data Service (bdsprod) service principal
        attach clusters to the VCN/subnet (when deploy_bds). Without this BDS
        cluster creation fails with "not enough permissions to access subnet
        or vcn details".

    Requires the caller to have IAM admin rights on the tenancy. Set to false
    if those rights are unavailable and pre-create the dynamic group + policies
    out of band (the bundled README has the matching rule and statements).
  EOT
  type        = bool
  default     = true
}

variable "bds_network_compartment_ocid" {
  description = <<-EOT
    Compartment that holds the VCN/subnet the BDS cluster attaches to. The
    bdsprod service policy is scoped here. Leave empty to use compartment_ocid
    (correct when create_vcn = true, or when an existing network lives in the
    same compartment). Set this only when reusing an existing VCN/subnet that
    resides in a different compartment.
  EOT
  type        = string
  default     = ""
}

variable "dataflow_create_logs_bucket" {
  description = "Create an Object Storage bucket for Data Flow logs."
  type        = bool
  default     = true
}

variable "dataflow_create_warehouse_bucket" {
  description = "Create an Object Storage bucket for Data Flow warehouse / SQL output."
  type        = bool
  default     = true
}

variable "dataflow_create_scripts_bucket" {
  description = "Create an Object Storage bucket for the bundled sample Spark scripts."
  type        = bool
  default     = true
}

variable "dataflow_upload_sample_scripts" {
  description = "Upload the sample Spark scripts (examples/) into the scripts bucket."
  type        = bool
  default     = true
}

variable "dataflow_create_pool" {
  description = "Create a Data Flow warm pool so applications launch with near-zero start-up latency."
  type        = bool
  default     = false
}

variable "dataflow_pool_min_executors" {
  description = "Minimum executor count kept warm in the Data Flow pool."
  type        = number
  default     = 1
}

variable "dataflow_pool_max_executors" {
  description = "Maximum executor count the Data Flow pool can scale to."
  type        = number
  default     = 4
}

variable "dataflow_pool_shape" {
  description = "Shape used by the Data Flow warm pool nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "dataflow_pool_ocpus" {
  description = "OCPUs per Data Flow pool node."
  type        = number
  default     = 4
}

variable "dataflow_pool_memory_gbs" {
  description = "Memory per Data Flow pool node in GB."
  type        = number
  default     = 32
}

# Applications are defined as a list-of-objects so the user can deploy as many
# showcase Spark jobs as they want, each with its own configuration.
variable "dataflow_applications" {
  description = <<-EOT
    List of Data Flow applications to deploy. Each entry showcases a different
    Spark configuration. Set to [] to skip application creation.

    Object schema:
      name            — display name suffix
      language        — PYTHON | JAVA | SCALA | SQL
      spark_version   — e.g. "3.5.0" | "3.2.1"
      file_uri        — Object Storage URI of the entry-point script/jar.
                        Leave empty to fall back to the bundled sample for the language.
      class_name      — required for JAVA/SCALA, otherwise empty
      arguments       — list of CLI arguments passed to the application
      driver_shape    — flex shape, e.g. VM.Standard.E4.Flex
      driver_ocpus
      driver_memory_gbs
      executor_shape
      executor_ocpus
      executor_memory_gbs
      num_executors
      configuration   — map of Spark properties (e.g. spark.sql.shuffle.partitions)
  EOT
  type = list(object({
    name                = string
    language            = string
    spark_version       = string
    file_uri            = optional(string, "")
    class_name          = optional(string, "")
    arguments           = optional(list(string), [])
    driver_shape        = optional(string, "VM.Standard.E4.Flex")
    driver_ocpus        = optional(number, 1)
    driver_memory_gbs   = optional(number, 16)
    executor_shape      = optional(string, "VM.Standard.E4.Flex")
    executor_ocpus      = optional(number, 1)
    executor_memory_gbs = optional(number, 16)
    num_executors       = optional(number, 2)
    configuration       = optional(map(string), {})
  }))
  default = [
    {
      name                = "pi-python"
      language            = "PYTHON"
      spark_version       = "3.5.0"
      num_executors       = 2
      driver_ocpus        = 1
      driver_memory_gbs   = 16
      executor_ocpus      = 1
      executor_memory_gbs = 16
      configuration = {
        "spark.sql.shuffle.partitions"         = "20"
        "spark.dynamicAllocation.enabled"      = "true"
        "spark.dynamicAllocation.minExecutors" = "1"
        "spark.dynamicAllocation.maxExecutors" = "4"
        # Data Flow validates this as a plain integer in [60, 600] — no "s" suffix.
        "spark.dynamicAllocation.executorIdleTimeout" = "60"
      }
    }
  ]

  validation {
    condition = alltrue([
      for a in var.dataflow_applications :
      contains(["PYTHON", "JAVA", "SCALA", "SQL"], a.language)
    ])
    error_message = "Each application's language must be PYTHON, JAVA, SCALA, or SQL."
  }
}

###############################################################################
# Operator VM + OCI Bastion
###############################################################################

variable "deploy_operator" {
  description = <<-EOT
    Deploy an operator VM (jump/control host) in the private subnet, reachable
    only through the OCI Bastion service. The use-case scripts are staged on it
    and it carries instance-principal auth so you can submit Data Flow runs and
    use Object Storage without API keys.
  EOT
  type        = bool
  default     = false
}

variable "create_bastion" {
  description = "Create an OCI Bastion targeting the private subnet. Set false to reuse an existing bastion."
  type        = bool
  default     = true
}

variable "operator_shape" {
  description = "Compute shape for the operator VM."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "operator_ocpus" {
  description = "OCPUs for the operator VM (flex shapes only)."
  type        = number
  default     = 2
}

variable "operator_memory_gbs" {
  description = "Memory (GB) for the operator VM (flex shapes only)."
  type        = number
  default     = 16
}

variable "operator_boot_volume_gbs" {
  description = "Boot volume size (GB) for the operator VM."
  type        = number
  default     = 50
}

variable "bastion_client_cidr_allow_list" {
  description = <<-EOT
    Comma-separated list of single-host /32 CIDRs allowed to initiate bastion
    sessions (e.g. "203.0.113.4/32" or "203.0.113.4/32,198.51.100.7/32"). There
    is intentionally no default — open ranges like 0.0.0.0/0 are rejected; you
    must list the specific client IP(s), each as /32.
  EOT
  type        = string
  default     = ""

  validation {
    condition = alltrue([
      for c in split(",", var.bastion_client_cidr_allow_list) :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", trimspace(c)))
      if trimspace(c) != ""
    ])
    error_message = "Each bastion_client_cidr_allow_list entry must be a single host in /32 form, e.g. 203.0.113.4/32 (open ranges like /24 or 0.0.0.0/0 are not allowed)."
  }
}

variable "bastion_max_session_ttl_seconds" {
  description = "Maximum bastion session TTL in seconds (1800–10800)."
  type        = number
  default     = 10800

  validation {
    condition     = var.bastion_max_session_ttl_seconds >= 1800 && var.bastion_max_session_ttl_seconds <= 10800
    error_message = "Bastion max session TTL must be between 1800 and 10800 seconds."
  }
}
