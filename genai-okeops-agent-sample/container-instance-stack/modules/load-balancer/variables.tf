# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_id" {
  description = "Compartment OCID where the load balancer is created."
  type        = string
}

variable "app_name" {
  description = "Base application name used for load balancer resource names."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet OCID for the load balancer."
  type        = string
}

variable "backend_port" {
  description = "Backend application port used by the health checker."
  type        = number
}

variable "certificate_id" {
  description = "OCI Certificates service certificate OCID used by the HTTPS listener."
  type        = string
}

variable "nsg_ids" {
  description = "Network security groups attached to this component."
  type        = list(string)
  default     = []
}
