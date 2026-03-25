# Copyright (c) 2022, 2024 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

locals {
  deploy_from_operator      = alltrue([var.create_bastion, var.create_operator])
  deploy_from_local         = alltrue([!local.deploy_from_operator, var.control_plane_is_public])
  operator_helm_values_path = "/home/${var.operator_user}/helm-values"
}

data "oci_containerengine_cluster_kube_config" "kube_config" {
  count = local.deploy_from_local ? 1 : 0
  cluster_id = module.oke.cluster_id
  endpoint   = "PUBLIC_ENDPOINT"
}

resource "local_file" "cluster_kube_config_file" {
  count = local.deploy_from_local ? 1 : 0
  content  = one(data.oci_containerengine_cluster_kube_config.kube_config.*.content)
  filename = "${path.root}/cluster_kubeconfig"
}

module "kyverno" {
  source = "./helm-module"
  bastion_host    = module.oke.bastion_public_ip
  bastion_user    = var.bastion_user
  operator_host   = module.oke.operator_private_ip
  operator_user   = var.bastion_user
  ssh_private_key = tls_private_key.stack_key.private_key_openssh

  deploy_from_operator = local.deploy_from_operator
  deploy_from_local    = local.deploy_from_local

  deployment_name           = "kyverno"
  helm_chart                = "kyverno/kyverno"
  namespace                 = "kyverno"
  helm_repository           = "https://kyverno.github.io/kyverno/"
  operator_helm_values_path = local.operator_helm_values_path
  pre_deployment_commands   = []
  post_deployment_commands  = []
  helm_template_values_override = ""
  helm_user_values_override = ""
  local_kubeconfig_path = "${path.root}/cluster_kubeconfig"
  depends_on            = [module.oke, local_file.cluster_kube_config_file]
}
