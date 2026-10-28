# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_id" {
  description = "Compartment OCID where the OCI Certificates service certificate is imported."
  type        = string
}

variable "certificate_name" {
  description = "Name for the imported certificate in OCI Certificates service."
  type        = string
}

variable "certificate_pem" {
  description = "Public certificate PEM to import."
  type        = string
}

variable "cert_chain_pem" {
  description = "Certificate authority chain PEM for the imported certificate."
  type        = string
}

variable "private_key_pem" {
  description = "Private key PEM for the imported certificate."
  type        = string
  sensitive   = true
}
