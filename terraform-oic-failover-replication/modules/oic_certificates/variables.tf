variable "compartment_id" {
  description = "OCI compartment in which to import the listener certificate."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for the OCI Certificates resource names."
  type        = string
}

variable "ssl_certificate_file_path" {
  description = "Path to the PEM-encoded public TLS certificate."
  type        = string

  validation {
    condition     = fileexists(pathexpand(var.ssl_certificate_file_path))
    error_message = "ssl_certificate_file_path must point to a readable certificate file."
  }
}

variable "ssl_ca_certificate_file_path" {
  description = "Path to the PEM-encoded CA/intermediate certificate chain."
  type        = string

  validation {
    condition     = fileexists(pathexpand(var.ssl_ca_certificate_file_path))
    error_message = "ssl_ca_certificate_file_path must point to a readable CA certificate file."
  }
}

variable "ssl_private_key_file_path" {
  description = "Path to the PEM-encoded private key for the TLS certificate."
  type        = string
  sensitive   = true

  validation {
    condition     = fileexists(pathexpand(var.ssl_private_key_file_path))
    error_message = "ssl_private_key_file_path must point to a readable private key file."
  }
}

variable "defined_tags" {
  description = "Defined tags applied to OCI Certificates resources."
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags applied to OCI Certificates resources."
  type        = map(string)
  default     = {}
}
