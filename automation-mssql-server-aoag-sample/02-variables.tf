# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "oci_config_profile" {
  description = "OCI CLI config profile to use from ~/.oci/config for a local deployment. Ignored by OCI Resource Manager."
  type        = string
  default     = "DEFAULT"
}

variable "execution_environment" {
  description = "Terraform execution environment. Use local for a workstation/OCI CLI deployment or resource_manager for an OCI Resource Manager stack."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "resource_manager"], var.execution_environment)
    error_message = "execution_environment must be either local or resource_manager."
  }
}

variable "region" {
  description = "OCI region in which to deploy the lab."
  type        = string
}

variable "compartment_id" {
  description = "OICCompartment OCID."
  type        = string
}

variable "dc_availability_domain" {
  description = "Optional AD override for DC-VM. Leave empty to select the first AD in the region."
  type        = string
  default     = ""
}

variable "windows_image_ocid" {
  description = "Windows Server image OCID available in var.region."
  type        = string
}

variable "sql1_availability_domain" {
  description = "Optional AD override for SQL1. Leave empty to select the first AD in the region."
  type        = string
  default     = ""
}

variable "sql2_availability_domain" {
  description = "Optional AD override for SQL2. Leave empty to select the second AD when available, otherwise the first AD."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Active Directory DNS domain name to create on DC-VM."
  type        = string
  default     = "mssqlaoag.demo"
}

variable "domain_netbios_name" {
  description = "Active Directory NetBIOS name."
  type        = string
  default     = "MSSQLAOAG"
}

variable "domain_admin_user" {
  description = "Domain admin account created by the DC automation script."
  type        = string
  default     = "domainadmin"
}

variable "domain_admin_password" {
  description = "Password used to create the domain admin account during DC first-boot automation. Stored in rendered instance metadata/state for this POC."
  type        = string
  sensitive   = true
  default     = ""
}

variable "sql_service_account_user" {
  description = "Dedicated domain account used for SQL Server and SQL Server Agent services."
  type        = string
  default     = "sqlsa"
}

variable "sql_service_account_password" {
  description = "Password for the SQL Server service account. If empty, domain_admin_password is reused for this POC."
  type        = string
  sensitive   = true
  default     = ""
}

variable "local_admin_user" {
  description = "Local Windows administrator user to configure for RDP on first boot."
  type        = string
  default     = "opc"
}

variable "windows_admin_password" {
  description = "Password for the local Windows Administrator and local_admin_user accounts. If empty, domain_admin_password is reused for this POC."
  type        = string
  sensitive   = true
  default     = ""
}

variable "auto_configure_domain_controller" {
  description = "When true, injects first-boot PowerShell user_data into DC-VM to install AD DS, promote the domain, and create the domain admin user."
  type        = bool
  default     = true
}

variable "auto_configure_windows_nodes" {
  description = "When true, injects first-boot PowerShell user_data into SQL nodes to set local Windows credentials, enable RDP, rename, point DNS to DC-VM, join the domain, and grant domainadmin RDP/local admin access."
  type        = bool
  default     = true
}

variable "auto_install_sql_server" {
  description = "When true, SQL node first-boot automation installs SQL Server after the node has joined the domain."
  type        = bool
  default     = true
}

variable "install_ssms" {
  description = "When true and auto_install_sql_server is true, install SQL Server Management Studio on SQL nodes."
  type        = bool
  default     = true
}

variable "sql_server_download_url" {
  description = "Official Microsoft SQL Server 2025 Standard Developer bootstrapper URL."
  type        = string
  default     = "https://go.microsoft.com/fwlink/?linkid=2344626"
}

variable "ssms_download_url" {
  description = "Official Microsoft SSMS 22 bootstrapper URL."
  type        = string
  default     = "https://aka.ms/ssms/22/release/vs_SSMS.exe"
}

variable "automation_artifact_expiration" {
  description = "RFC3339 expiration for the private Object Storage PARs used by Windows first-boot automation. Refresh this before a deployment after the expiry date."
  type        = string
  default     = "2030-01-01T00:00:00Z"
}

variable "auto_configure_wsfc" {
  description = "When true, SQL1 launches the WSFC automation after SQL1/SQL2 are domain joined and SQL Server is installed."
  type        = bool
  default     = true
}

variable "wsfc_cluster_name" {
  description = "Windows Server Failover Cluster name."
  type        = string
  default     = "SQLAGCLUSTER"
}

variable "wsfc_cluster_ip_sql1" {
  description = "Reserved WSFC cluster IP on the SQL1 subnet."
  type        = string
  default     = "10.0.20.20"
}

variable "wsfc_cluster_ip_sql2" {
  description = "Reserved WSFC cluster IP on the SQL2 subnet."
  type        = string
  default     = "10.0.30.20"
}

variable "wsfc_witness_path" {
  description = "Local folder on DC-VM published as the file share witness."
  type        = string
  default     = "C:\\ClusterWitness"
}

variable "wsfc_witness_share_name" {
  description = "SMB share name for the WSFC file share witness."
  type        = string
  default     = "ClusterWitness"
}

variable "skip_cluster_validation" {
  description = "When true, WSFC automation skips Test-Cluster before New-Cluster."
  type        = bool
  default     = true
}

variable "aoag_database_name" {
  description = "Database used for the initial Always On availability group."
  type        = string
  default     = "AdventureWorks2025"
}

variable "aoag_availability_group_name" {
  description = "Initial Always On availability group name."
  type        = string
  default     = "TestAOAG"
}

variable "aoag_listener_name" {
  description = "Native availability group listener DNS name."
  type        = string
  default     = "AOAG-LSN"
}

variable "aoag_listener_port" {
  description = "Native availability group listener TCP port."
  type        = number
  default     = 1433
}

variable "aoag_listener_ip_sql1" {
  description = "Reserved availability group listener IP on the SQL1 subnet."
  type        = string
  default     = "10.0.20.30"
}

variable "aoag_listener_ip_sql2" {
  description = "Reserved availability group listener IP on the SQL2 subnet."
  type        = string
  default     = "10.0.30.30"
}

variable "hadr_endpoint_name" {
  description = "SQL Server Database Mirroring endpoint used by Always On."
  type        = string
  default     = "Hadr_endpoint"
}

variable "hadr_endpoint_port" {
  description = "TCP port for the Always On HADR endpoint."
  type        = number
  default     = 5022
}

variable "sample_database_download_url" {
  description = "URL for the sample SQL Server database backup."
  type        = string
  default     = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2025.bak"
}

variable "vcn_name" {
  description = "VCN display name."
  type        = string
  default     = "SQL_VCN"
}

variable "vcn_dns_label" {
  description = "VCN DNS label."
  type        = string
  default     = "sqlvcn"
}

variable "vcn_cidr" {
  description = "VCN IPv4 CIDR block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dc_subnet_cidr" {
  type    = string
  default = "10.0.10.0/24"
}

variable "sql1_subnet_cidr" {
  type    = string
  default = "10.0.20.0/24"
}

variable "sql2_subnet_cidr" {
  type    = string
  default = "10.0.30.0/24"
}

variable "dc_private_ip" {
  type    = string
  default = "10.0.10.10"
}

variable "sql1_private_ip" {
  type    = string
  default = "10.0.20.10"
}

variable "sql2_private_ip" {
  type    = string
  default = "10.0.30.10"
}

variable "shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}

variable "ocpus" {
  description = "OCPUs for DC-VM."
  type        = number
  default     = 6
}

variable "sql_ocpus" {
  description = "OCPUs for SQL1 and SQL2."
  type        = number
  default     = 8
}

variable "memory_in_gbs" {
  description = "Memory for DC-VM."
  type        = number
  default     = 16
}

variable "sql_memory_in_gbs" {
  description = "Memory for SQL1 and SQL2."
  type        = number
  default     = 32
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size for DC-VM, SQL1, and SQL2."
  type        = number
  default     = 100
}

variable "sql_data_volume_size_in_gbs" {
  description = "Persistent block volume size attached to each SQL node for SQL data, logs, and backups."
  type        = number
  default     = 100
}

variable "sql_data_drive_letter" {
  description = "Windows drive letter assigned to each SQL node's persistent data volume."
  type        = string
  default     = "F"
}

variable "dc_rdp_source_cidr" {
  description = "Source CIDR allowed to RDP into DC-VM."
  type        = string
  default     = "0.0.0.0/0"
}

variable "sql_rdp_source_cidr" {
  description = "Source CIDR allowed to RDP into SQL1 and SQL2."
  type        = string
  default     = "0.0.0.0/0"
}

variable "freeform_tags" {
  type = map(string)
  default = {
    Project = "sqlagtest"
  }
}
