variable "tenancy_ocid" {
  description = "OCI tenancy OCID."
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID used by the provider."
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint for the OCI user."
  type        = string
}

variable "private_key_path" {
  description = "Path to the private key used by the OCI provider."
  type        = string
}

variable "primary_region" {
  description = "OCI region where the primary OIC instance will be created."
  type        = string
}

variable "tenancy_home_region" {
  description = "OCI tenancy home region used for tenancy-level IAM and globally scoped DNS resources."
  type        = string
}

variable "secondary_region" {
  description = "OCI region where the secondary OIC instance will be created."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID for the OIC instance."
  type        = string
}

variable "vcn_cidr" {
  description = "IPv4 CIDR block for the primary VCN."
  type        = string
}

variable "public_subnet_cidr" {
  description = "IPv4 CIDR block for the public subnet in the primary VCN."
  type        = string
}

variable "functions_subnet_cidr" {
  description = "IPv4 CIDR block for the private subnet used by the secondary-region OIC DR replication function."
  type        = string
}

variable "oic_dr_replication_schedule_start_time" {
  description = "Optional RFC3339 UTC start time for the hourly resource schedule. If unset, OCI schedules the first run automatically."
  type        = string
}

variable "identity_domain_id" {
  description = "Identity Domain OCID used by OIC and the OAuth client app."
  type        = string
}

variable "primary_oic_display_name" {
  description = "Display name for the Oracle Integration instance."
  type        = string
}

variable "secondary_oic_display_name" {
  description = "Display name for the secondary Oracle Integration instance."
  type        = string
}

variable "oic_integration_instance_type" {
  description = "OIC instance type. Common values: STANDARDX, ENTERPRISEX."
  type        = string
}

variable "secondary_oic_integration_instance_type" {
  description = "OIC instance type for the secondary instance."
  type        = string
}

variable "oic_shape" {
  description = "OIC instance shape. Common values: DEVELOPMENT, PRODUCTION."
  type        = string
}

variable "secondary_oic_shape" {
  description = "OIC instance shape for the secondary instance."
  type        = string
}

variable "oic_is_byol" {
  description = "Whether the OIC instance uses BYOL."
  type        = bool
}

variable "secondary_oic_is_byol" {
  description = "Whether the secondary OIC instance uses BYOL."
  type        = bool
}

variable "oic_message_packs" {
  description = "Number of message packs to allocate."
  type        = number
}

variable "secondary_oic_message_packs" {
  description = "Number of message packs to allocate for the secondary OIC instance."
  type        = number
}

variable "oic_defined_tags" {
  description = "Defined tags for the OIC instance."
  type        = map(string)
}

variable "secondary_oic_defined_tags" {
  description = "Defined tags for the secondary OIC instance."
  type        = map(string)
}

variable "oic_freeform_tags" {
  description = "Freeform tags for the OIC instance."
  type        = map(string)
}

variable "secondary_oic_freeform_tags" {
  description = "Freeform tags for the secondary OIC instance."
  type        = map(string)
}

variable "primary_client_app_display_name" {
  description = "Display name for the primary Identity Domains OAuth client application."
  type        = string
}

variable "secondary_client_app_display_name" {
  description = "Display name for the secondary Identity Domains OAuth client application."
  type        = string
}

variable "client_app_description" {
  description = "Description for the Identity Domains OAuth client application."
  type        = string
}

variable "client_allowed_scope_fqs" {
  description = "Additional OIC scopes for each matching client app, either fully-qualified or simple scope names. All scopes exposed by the matching OIC resource application are included automatically."
  type        = list(string)
}

variable "client_access_token_expiry" {
  description = "OAuth access token expiry in seconds."
  type        = number
}

variable "client_refresh_token_expiry" {
  description = "OAuth refresh token expiry in seconds."
  type        = number
}

variable "client_bypass_consent" {
  description = "Skip user consent for the configured scopes."
  type        = bool
}

variable "client_trust_scope" {
  description = "Trust scope for the OAuth client app."
  type        = string
}

variable "client_active" {
  description = "Whether the OAuth client app is active."
  type        = bool
}


variable "steering_policy_display_name" {
  description = "Display name for the DNS failover steering policy."
  type        = string
}

variable "domain_hostname" {
  description = "The DNS zone name. The failover steering policy is attached at oic.<domain_hostname>."
  type        = string
}

variable "dns_zone_scope" {
  description = "Scope of the public DNS zone."
  type        = string
}

variable "dns_zone_type" {
  description = "Type of the public DNS zone."
  type        = string
}

variable "primary_create_functions_subnet" {
  description = "Whether to create an OCI Functions subnet in the primary VCN."
  type        = bool
}

variable "secondary_create_functions_subnet" {
  description = "Whether to create an OCI Functions subnet in the secondary VCN."
  type        = bool
}

variable "ssl_certificate_file_path" {
  description = "Path to the PEM-encoded public SSL certificate used by both load balancer HTTPS listeners."
  type        = string

  validation {
    condition     = fileexists(pathexpand(var.ssl_certificate_file_path))
    error_message = "ssl_certificate_file_path must point to a readable certificate file."
  }
}

variable "ssl_ca_certificate_file_path" {
  description = "Path to the PEM-encoded CA/intermediate certificate chain used by both load balancer HTTPS listeners."
  type        = string

  validation {
    condition     = fileexists(pathexpand(var.ssl_ca_certificate_file_path))
    error_message = "ssl_ca_certificate_file_path must point to a readable CA certificate file."
  }
}

variable "ssl_private_key_file_path" {
  description = "Path to the PEM-encoded private key used by both load balancer HTTPS listeners."
  type        = string
  sensitive   = true

  validation {
    condition     = fileexists(pathexpand(var.ssl_private_key_file_path))
    error_message = "ssl_private_key_file_path must point to a readable private key file."
  }
}
