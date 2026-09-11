# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    oci = {
      source  = "oracle/oci"
      version = "~> 8.13"
    }
  }
}

provider "oci" {
  config_file_profile = var.config_file_profile
  region              = var.region
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca_certificate

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args        = local.kube_exec_args
    }
  }
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca_certificate
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.kube_exec_args
  }
}
