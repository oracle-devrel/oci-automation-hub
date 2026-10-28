# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  type = string
}

variable "name" {
  type = string
}

variable "vcn_id" {
  type = string
}

variable "endpoint_subnet_id" {
  type = string
}

variable "worker_subnet_id" {
  type = string
}

variable "public_endpoint" {
  type = bool
}

variable "kubernetes_version" {
  type = string
}

variable "availability_domain" {
  type = string
}

variable "node_shape" {
  type = string
}

variable "node_image_id" {
  type = string
}

variable "node_count" {
  type = number
}

variable "ssh_public_key" {
  type = string
}

variable "endpoint_nsg_ids" {
  description = "Network security groups attached to this component."
  type        = list(string)
  default     = []
}

variable "worker_nsg_ids" {
  description = "Network security groups attached to this component."
  type        = list(string)
  default     = []
}
