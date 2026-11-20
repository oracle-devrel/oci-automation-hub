# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "load_balancer_id" {
  description = "OCID of the load balancer."
  type        = string
}

variable "backendset_name" {
  description = "Name of the backend set."
  type        = string
}

variable "backend_ip_address" {
  description = "Private IP address of the Container Instance backend."
  type        = string
}

variable "backend_port" {
  description = "Backend application port."
  type        = number
}
