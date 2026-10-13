variable "idcs_endpoint" {
  description = "Identity Domains endpoint URL for the region's OAuth client."
  type        = string
}

variable "client_id" {
  description = "OAuth client ID (the Identity Domains application name)."
  type        = string
}

variable "client_secret" {
  description = "OAuth client secret."
  type        = string
  sensitive   = true
}

variable "scope_fqs" {
  description = "Fully-qualified OAuth scopes to request for the matching OIC instance."
  type        = list(string)

  validation {
    condition     = length(var.scope_fqs) > 0
    error_message = "At least one OAuth scope must be supplied to request a bearer token."
  }
}
