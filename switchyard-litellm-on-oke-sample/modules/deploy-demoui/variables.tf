# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "repositories" {
  description = "OCI container repositories to create."

  type = map(object({
    compartment_id                    = string
    container_repository_is_immutable = optional(bool, false)
    container_repository_is_public    = optional(bool, false)
    defined_tags                      = optional(map(string), {})
    freeform_tags                     = optional(map(string), {})
  }))
}

variable "demoui_install" { type = bool }
variable "demoui_namespace" { type = string }
variable "demoui_release_name" { type = string }
variable "demoui_repository_name" { type = string }
variable "is_demoui_lb_public" {
  type    = bool
  default = true
}
variable "demoui_load_balancer_nsg_id" { type = string }
variable "demoui_cluster_id" { type = string }
variable "bastion_host" {}
variable "bastion_user" {}
variable "ssh_private_key" {
  type      = string
  sensitive = true
}
variable "operator_host" {}
variable "operator_user" {}

variable "ocir_username" {}
variable "ocir_auth_token" {
  type      = string
  sensitive = true
}

variable "region" {}
