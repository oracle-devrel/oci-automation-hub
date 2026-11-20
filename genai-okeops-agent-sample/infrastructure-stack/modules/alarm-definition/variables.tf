# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "The OCID of the compartment where the alarm definition will be created."
  type        = string
}
variable "stream_id" {
  description = "OCI for the destination OCI Stream."
  type        = string
}
variable "display_name" {
  description = "Display name for the alarm definition."
  type        = string

}
variable "cluster_id" {
  description = "OCID of the OKE cluster to monitor."
  type        = string
}
