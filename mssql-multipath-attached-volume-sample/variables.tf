# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

#variable "provider_oci" {
#  description = "OCI provider authentication and region values."
#  type = object({
#    tenancy       = string
#    user_id       = string
#    fingerprint   = string
#    key_file_path = string
#    region        = string
#  })
#}

variable "config_file_profile" {
  description = "OCI CLI config profile used by the OCI Terraform provider."
  type        = string
  default     = "DEFAULT"
}

variable "tenancy_ocid" {
  description = "Tenancy OCID."
  type        = string
}


variable "compartment_ocid" {
  description = "Compartment OCID where compute and block volumes will be created."
  type        = string
}

variable "freeform_tags" {
  description = "Global freeform tags merged into compute and block volume resources."
  type        = map(string)
  default     = {}
}

variable "enable_agent_auto_iscsi_login" {
  description = "Enable OCI agent automatic iSCSI login on Linux iSCSI volume attachments. Keep false when cloud-init performs manual iSCSI login."
  type        = bool
  default     = false
}

variable "instance_params" {
  description = "Compute instances keyed by instance key (map object style, similar to Thunder instance_params)."
  type = map(object({
    ad                      = number
    os_type                 = string
    display_name            = string
    shape                   = string
    hostname                = string
    subnet_ocid             = string
    image_ocid              = string
    boot_volume_size_in_gbs = number
    assign_public_ip        = bool
    ssh_public_key          = optional(string, "")
    nsg_ocids               = optional(list(string), [])
    shape_config = optional(object({
      ocpus         = number
      memory_in_gbs = number
    }))
    freeform_tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for instance_key, params in var.instance_params :
      contains(["linux", "windows"], lower(params.os_type))
    ])
    error_message = "instance_params[*].os_type must be linux or windows."
  }

  validation {
    condition = alltrue([
      for instance_key, params in var.instance_params :
      floor(params.ad) == params.ad && params.ad >= 1
    ])
    error_message = "instance_params[*].ad must be a positive integer (1, 2, 3, ...)."
  }

  validation {
    condition = alltrue([
      for instance_key, params in var.instance_params :
      lower(params.os_type) != "linux" || length(trimspace(try(params.ssh_public_key, ""))) > 0
    ])
    error_message = "Each Linux instance in instance_params must include ssh_public_key."
  }
}

variable "bv_params" {
  description = "Block volumes keyed by volume key (map object style, similar to Thunder bv_params). Use instance_key to bind a volume to an instance."
  type = map(object({
    ad              = optional(number)
    display_name    = string
    bv_size         = number
    instance_key    = string
    device_name     = string
    attachment_type = optional(string, "iscsi")
    vpus_per_gb     = optional(number, 10)
    use_chap        = optional(bool, false)
    raid0_group     = optional(string, "")
    filesystem_type = optional(string, "xfs")
    mount_point     = optional(string, "")
    freeform_tags   = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for bv_key, params in var.bv_params :
      params.bv_size > 0
    ])
    error_message = "bv_params[*].bv_size must be greater than 0."
  }

  validation {
    condition = alltrue([
      for bv_key, params in var.bv_params :
      contains(["iscsi", "paravirtualized"], lower(trimspace(try(params.attachment_type, "iscsi"))))
    ])
    error_message = "bv_params[*].attachment_type must be iscsi or paravirtualized."
  }

  validation {
    condition = alltrue([
      for bv_key, params in var.bv_params :
      contains(["xfs", "ext4", "ntfs", "refs"], lower(trimspace(try(params.filesystem_type, "xfs"))))
    ])
    error_message = "bv_params[*].filesystem_type must be xfs, ext4, ntfs, or refs."
  }

  validation {
    condition = alltrue([
      for bv_key, params in var.bv_params :
      floor(coalesce(params.ad, 1)) == coalesce(params.ad, 1) && coalesce(params.ad, 1) >= 1
    ])
    error_message = "When set, bv_params[*].ad must be a positive integer (1, 2, 3, ...)."
  }
}

variable "linux_timezone" {
  description = "Timezone configured by Linux cloud-init."
  type        = string
  default     = "UTC"
}

variable "linux_mssql_pid" {
  description = "Linux SQL Server edition identifier (for example: Developer, Express, Standard, Enterprise)."
  type        = string
  default     = "Developer"
}

variable "linux_mssql_sa_password" {
  description = "SA password for Linux SQL Server setup."
  type        = string
  sensitive   = true
  default     = ""
}

variable "linux_sql_tcp_port" {
  description = "Linux SQL Server TCP port."
  type        = number
  default     = 1433
}

variable "linux_install_mssql_tools" {
  description = "Install sqlcmd and related tooling on Linux."
  type        = bool
  default     = true
}

variable "linux_open_firewall" {
  description = "Open Linux firewall for SQL Server TCP port."
  type        = bool
  default     = false
}

variable "linux_enable_mssql_agent" {
  description = "Enable SQL Server Agent on Linux."
  type        = bool
  default     = true
}

variable "linux_mssql_configure_memory" {
  description = "Whether to set SQL Server max memory on Linux."
  type        = bool
  default     = false
}

variable "linux_mssql_memory_limit_mb" {
  description = "SQL Server max memory in MB when linux_mssql_configure_memory is true."
  type        = number
  default     = 4096
}

variable "linux_mssql_default_data_dir" {
  description = "Default SQL data directory on Linux."
  type        = string
  default     = "/var/opt/mssql/data"
}

variable "linux_mssql_default_log_dir" {
  description = "Default SQL log directory on Linux."
  type        = string
  default     = "/var/opt/mssql/log"
}

variable "linux_mssql_default_backup_dir" {
  description = "Default SQL backup directory on Linux."
  type        = string
  default     = "/var/opt/mssql/backup"
}

variable "linux_volume_mount_owner" {
  description = "Owner applied to Linux block volume mount points after mounting."
  type        = string
  default     = "mssql"
}

variable "linux_volume_mount_group" {
  description = "Group applied to Linux block volume mount points after mounting."
  type        = string
  default     = "mssql"
}

variable "linux_volume_mount_mode" {
  description = "Filesystem mode applied to Linux block volume mount points after mounting."
  type        = string
  default     = "0770"
}

variable "windows_mssql_sa_password" {
  description = "SA password for Windows SQL Server setup."
  type        = string
  sensitive   = true
  default     = ""
}

variable "windows_sql_instance_name" {
  description = "SQL Server instance name for Windows."
  type        = string
  default     = "SQLEXPRESS"
}

variable "windows_sql_features" {
  description = "Windows SQL Server features to install."
  type        = string
  default     = "SQLENGINE"
}

variable "windows_sql_tcp_port" {
  description = "Windows SQL Server TCP port."
  type        = number
  default     = 1433
}

variable "windows_choco_package_name" {
  description = "Chocolatey package used to install SQL Server on Windows."
  type        = string
  default     = "sql-server-express"
}

variable "windows_open_firewall" {
  description = "Open Windows firewall for SQL Server TCP port."
  type        = bool
  default     = true
}

variable "windows_sql_collation" {
  description = "Windows SQL Server collation name."
  type        = string
  default     = "SQL_Latin1_General_CP1_CI_AS"
}
