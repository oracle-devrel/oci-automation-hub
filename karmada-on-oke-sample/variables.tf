# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

#provider
variable "tenancy_ocid" {
}


variable "compartment_ocid" {
}

variable "region" {
}

# vcn

variable "cidr_blocks" {
  type = any
}

variable "vcn_display_name" {
  type = string
}

# subnets
variable "api_endpoint_subnet_cidr" {
  type = string
}

variable "lb_subnet_cidr" {
  type = string
}

variable "nodepool_subnet_cidr" {
  type = string
}

variable "pods_subnet_cidr" {
  type = string
}

variable "ssh_public_key" {
  type = string
}