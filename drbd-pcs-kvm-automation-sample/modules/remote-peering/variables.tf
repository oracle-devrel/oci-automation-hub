# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "compartment_id" {
  type = string
}

variable "drg_ids" {
  type = map(string)
}

variable "requestor_params" {
  type = object({
    drg_name         = string
  })
}

variable "requestor_region" {
  type = string
}

variable "acceptor_params" {
  type = object({
    drg_name         = string 
  })
}

variable "acceptor_region" {
  type = string
}
