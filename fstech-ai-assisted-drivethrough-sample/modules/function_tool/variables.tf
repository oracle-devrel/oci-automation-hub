# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "agent_id" {
  type = string
}

variable "compartment_id" {
  type = string
}

variable "name" {
  type = string
}

variable "description" {
  type = string
}

variable "parameters" {
  type = map(string)
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}
