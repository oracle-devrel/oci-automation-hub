# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "litellm_install" { type = bool }
variable "litellm_namespace" { type = string }
variable "litellm_release_name" { type = string }
variable "litellm_helm_version" { type = string }
variable "litellm_helm_values" { type = map(string) }
variable "litellm_helm_values_files" { type = list(string) }
variable "litellm_postgresql_manifest_file" { type = string }

variable "create_iam_resources" {
  type = bool
}

variable "create_iam_operator_policy" {
  type = string
}

variable "bastion_host" {}
variable "bastion_user" {}
variable "ssh_private_key" {}
variable "operator_host" {}
variable "operator_user" {}

variable "nvidia_api_key" {
  type      = string
  sensitive = true
}
