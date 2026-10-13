variable "idcs_endpoint" {
  description = "Identity Domain endpoint URL."
  type        = string
}

variable "display_name" {
  description = "Display name for the OAuth client application."
  type        = string
}

variable "description" {
  description = "Description for the OAuth client application."
  type        = string
  default     = null
}

variable "allowed_scope_fqs" {
  description = "Fully qualified scopes this client may request."
  type        = list(string)
  default     = []
}

variable "access_token_expiry" {
  description = "Access token expiry in seconds."
  type        = number
  default     = 3600
}

variable "refresh_token_expiry" {
  description = "Refresh token expiry in seconds."
  type        = number
  default     = 86400
}

variable "bypass_consent" {
  description = "Whether consent is bypassed for the allowed scopes."
  type        = bool
  default     = true
}

variable "trust_scope" {
  description = "Trust scope for the OAuth client."
  type        = string
  default     = "Explicit"
}

variable "active" {
  description = "Whether the client app is active."
  type        = bool
  default     = true
}
