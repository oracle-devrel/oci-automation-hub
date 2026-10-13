variable "compartment_id" {
  description = "OCID of the compartment in which to create the Function resources."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the tenancy, used for the scheduler policy."
  type        = string
}

variable "secondary_region" {
  description = "OCI region that hosts the replication Function and OCIR image."
  type        = string
}

variable "subnet_id" {
  description = "OCID of a private subnet with outbound NAT access."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for Function, application, scheduler, and IAM resource names."
  type        = string
}

variable "primary_oic_url" {
  description = "Base URL of the primary Oracle Integration instance."
  type        = string
}

variable "secondary_oic_url" {
  description = "Base URL of the secondary Oracle Integration instance."
  type        = string
}

variable "idcs_endpoint" {
  description = "Identity Domains endpoint used to obtain OAuth bearer tokens."
  type        = string
}

variable "primary_client_id" {
  description = "OAuth client ID for the primary OIC instance."
  type        = string
}

variable "primary_client_secret" {
  description = "OAuth client secret for the primary OIC instance."
  type        = string
  sensitive   = true
}

variable "primary_scope_fqs" {
  description = "OAuth scopes to request for primary OIC API calls."
  type        = list(string)
}

variable "secondary_client_id" {
  description = "OAuth client ID for the secondary OIC instance."
  type        = string
}

variable "secondary_client_secret" {
  description = "OAuth client secret for the secondary OIC instance."
  type        = string
  sensitive   = true
}

variable "secondary_scope_fqs" {
  description = "OAuth scopes to request for secondary OIC API calls."
  type        = list(string)
}

variable "role_grant_ids" {
  description = "Identity Domains grant IDs that must exist before creating the replication Function."
  type        = list(string)
}

variable "schedule_start_time" {
  description = "Optional RFC3339 UTC time at which the hourly schedule starts."
  type        = string
  default     = null
}

variable "function_memory_in_mbs" {
  description = "Memory allocated to the replication function."
  type        = number
  default     = 1024
}

variable "function_timeout_in_seconds" {
  description = "Maximum run time of the replication function."
  type        = number
  default     = 300
}

variable "freeform_tags" {
  description = "Freeform tags for all supported resources."
  type        = map(string)
  default     = {}
}
