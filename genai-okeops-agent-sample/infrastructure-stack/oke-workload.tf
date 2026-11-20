# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source = "oracle/oci"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}

provider "oci" {
  region = var.region
}

data "oci_containerengine_cluster_kube_config" "this" {
  cluster_id    = module.oke.cluster_id
  endpoint      = var.oke_public_endpoint ? "PUBLIC_ENDPOINT" : "PRIVATE_ENDPOINT"
  token_version = "2.0.0"
}

locals {
  kubeconfig = yamldecode(data.oci_containerengine_cluster_kube_config.this.content)
}

provider "kubernetes" {
  host                   = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = ["ce", "cluster", "generate-token", "--cluster-id", module.oke.cluster_id, "--region", var.region, "--auth", var.kubernetes_cli_auth]
  }
}

resource "kubernetes_namespace_v1" "demo" {
  metadata {
    name = "okeops-demo"
  }
  depends_on = [module.oke]
}

resource "kubernetes_pod_v1" "unschedulable" {
  metadata {
    name      = "unschedulable-demo"
    namespace = kubernetes_namespace_v1.demo.metadata[0].name
  }
  # No worker has this label, so the scheduler reports FailedScheduling.
  spec {
    node_selector = {
      "okeops.oracle.com/demo-target" = "nonexistent"
    }
    automount_service_account_token = false
    container {
      name  = "pause"
      image = "registry.k8s.io/pause:3.10"
      resources {
        requests = {
          cpu    = "10m"
          memory = "16Mi"
        }
        limits = {
          cpu    = "10m"
          memory = "16Mi"
        }
      }
    }
  }
  # Pending is intentional: waiting for Running would cause apply to time out.
  target_state = ["Pending"]
}
