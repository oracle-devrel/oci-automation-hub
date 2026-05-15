# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "https://oracle.github.io/karpenter-provider-oci/charts"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  namespace        = var.karpenter_namespace
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [
    yamlencode({
      replicaCount = var.karpenter_controller_replicas

      serviceAccount = {
        create = true
        name   = var.karpenter_service_account_name
      }

      controller = {
        env = [
          {
            name  = "OCI_RESOURCE_PRINCIPAL_VERSION"
            value = "2.2"
          },
          {
            name  = "OCI_REGION"
            value = var.region
          }
        ]
      }

      settings = {
        clusterCompartmentId       = var.project_compartment_ocid
        vcnCompartmentId           = var.project_compartment_ocid
        preBakedImageCompartmentId = var.oke_image_compartment_ocid
        apiserverEndpoint          = local.cluster_private_endpoint
        ociVcnIpNative             = var.cni_type == "OCI_VCN_IP_NATIVE"
      }
    })
  ]

  depends_on = [
    oci_containerengine_node_pool.bootstrap,
    oci_identity_policy.karpenter_nodes_join,
    oci_identity_policy.karpenter_tenancy_inspect,
    oci_identity_policy.karpenter_workload
  ]
}

resource "kubectl_manifest" "optimized_oci_node_class" {
  yaml_body = yamlencode({
    apiVersion = "oci.oraclecloud.com/v1beta1"
    kind       = "OCINodeClass"
    metadata = {
      name = var.karpenter_nodepool_name
    }
    spec = {
      nodeCompartmentId = var.project_compartment_ocid
      sshAuthorizedKeys = [local.ssh_public_key]
      shapeConfigs      = local.karpenter_shape_configs

      metadata = {
        user_data = local.optimized_node_user_data
      }

      volumeConfig = {
        bootVolumeConfig = {
          sizeInGbs = var.worker_boot_volume_size_in_gbs
          imageConfig = {
            imageType = "OKEImage"
            imageId   = oci_core_image.optimized_oke_worker.id
          }
        }
      }

      networkConfig = local.ocinodeclass_network_config

      freeformTags = local.common_tags
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "optimized_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = var.karpenter_nodepool_name
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "oke-optimization.oracle.com/profile" = "fast-start"
          }
        }
        spec = {
          expireAfter = "Never"
          nodeClassRef = {
            group = "oci.oraclecloud.com"
            kind  = "OCINodeClass"
            name  = var.karpenter_nodepool_name
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "oci.oraclecloud.com/instance-shape"
              operator = "In"
              values   = var.karpenter_worker_shapes
            }
          ]
          taints = [
            {
              key    = "oke-optimization.oracle.com/scaling-test"
              value  = "true"
              effect = "NoSchedule"
            }
          ]
          terminationGracePeriod = "2m"
        }
      }
      disruption = {
        budgets = [
          {
            nodes = "100%"
          }
        ]
        consolidateAfter    = "30s"
        consolidationPolicy = "WhenEmptyOrUnderutilized"
      }
      limits = {
        cpu    = var.karpenter_node_cpu_limit
        memory = var.karpenter_node_memory_limit
      }
    }
  })

  depends_on = [kubectl_manifest.optimized_oci_node_class]
}
