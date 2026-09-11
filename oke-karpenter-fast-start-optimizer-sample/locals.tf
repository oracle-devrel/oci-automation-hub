# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  ssh_public_key = file(pathexpand(var.ssh_public_key_path))

  worker_image_id = var.oke_worker_image_id != null ? var.oke_worker_image_id : data.oci_core_images.oke_worker[0].images[0].id

  kubeconfig          = yamldecode(data.oci_containerengine_cluster_kube_config.this.content)
  kube_host           = local.kubeconfig.clusters[0].cluster.server
  kube_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  kube_exec_args = [
    "ce",
    "cluster",
    "generate-token",
    "--cluster-id",
    oci_containerengine_cluster.this.id,
    "--region",
    var.region,
    "--profile",
    var.config_file_profile
  ]

  cluster_private_endpoint = replace(
    replace(
      replace(oci_containerengine_cluster.this.endpoints[0].private_endpoint, "https://", ""),
      "http://",
      ""
    ),
    ":6443",
    ""
  )

  karpenter_shape_configs = [
    for shape_config in var.karpenter_shape_configs : merge(
      {
        ocpus       = shape_config.ocpus
        memoryInGbs = shape_config.memory_in_gbs
      },
      shape_config.baseline_ocpu_utilization == null ? {} : {
        baselineOcpuUtilization = shape_config.baseline_ocpu_utilization
      }
    )
  ]

  ocinodeclass_network_config = merge(
    {
      primaryVnicConfig = {
        subnetConfig = {
          subnetId = oci_core_subnet.workers.id
        }
      }
    },
    var.cni_type == "OCI_VCN_IP_NATIVE" ? {
      secondaryVnicConfigs = [
        {
          subnetConfig = {
            subnetId = oci_core_subnet.pods.id
          }
          ipCount = var.karpenter_pod_vnic_ip_count
        }
      ]
    } : {}
  )

  optimized_node_user_data = base64encode(templatefile("${path.module}/templates/karpenter-optimized-user-data.sh.tftpl", {
    cluster_dns_ip = var.cluster_dns_ip
    prepull_images = var.prepull_images
  }))

  base_worker_image_display_name      = var.oke_worker_image_id == null ? data.oci_core_images.oke_worker[0].images[0].display_name : var.oke_worker_image_display_name
  optimized_worker_image_display_name = "${var.name}-ol8-oke-${replace(trimprefix(var.kubernetes_version, "v"), ".", "-")}-fast-start"
  optimized_worker_image_tags = merge(local.common_tags, {
    k8s_version          = var.kubernetes_version
    base_image_ocid      = local.worker_image_id
    base_image_name      = local.base_worker_image_display_name
    optimization_profile = "fast-start"
  })

  common_tags = merge(var.freeform_tags, {
    Environment = var.name
  })
}
