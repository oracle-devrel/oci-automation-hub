# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  create_iam_resources       = true
  create_iam_operator_policy = "always"

  user_public_ssh_key     = var.ssh_public_key != "" ? chomp(var.ssh_public_key) : ""
  bundled_ssh_public_keys = var.ssh_public_key != "" ? "${local.user_public_ssh_key}\n${chomp(tls_private_key.stack_key.public_key_openssh)}" : "${chomp(tls_private_key.stack_key.public_key_openssh)}"
  demoui_chart_values     = yamldecode(file("${path.root}/modules/deploy-demoui/demoui-app/charts/demo-ui/values.yaml"))
}

resource "tls_private_key" "stack_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content  = tls_private_key.stack_key.private_key_openssh
  filename = format("%s/%s/%s", path.root, "private", "id_rsa")
}


module "oke" {
  source                            = "oracle-terraform-modules/oke/oci"
  version                           = "5.5.2"
  create_iam_operator_policy        = local.create_iam_operator_policy
  create_iam_resources              = local.create_iam_resources
  allow_short_container_image_names = true

  allow_rules_public_lb = local.demoui_chart_values.loadbalancer.enabled ? {
    "Allow HTTP access to demo UI load balancer" = {
      protocol    = 6
      port        = local.demoui_chart_values.loadbalancer.port
      source      = "0.0.0.0/0"
      source_type = "CIDR_BLOCK"
      stateless   = false
    }
  } : {}

  state_id = var.state_id
  providers = {
    oci.home = oci.home
  }
  tenancy_id        = var.tenancy_ocid
  compartment_id    = coalesce(var.compartment_id, var.compartment_ocid)
  current_user_ocid = null

  ssh_private_key       = tls_private_key.stack_key.private_key_openssh
  ssh_public_key        = local.bundled_ssh_public_keys
  bastion_allowed_cidrs = var.bastion_allowed_cidrs
  bastion_image_type    = var.bastion_image_type
  bastion_shape         = { "boot_volume_size" : 50, "memory" : 4, "ocpus" : 1, "shape" : "VM.Standard.E5.Flex" }
  # Operator variables
  operator_image_type       = var.operator_image_type
  operator_image_os         = "Oracle Linux"
  operator_image_os_version = "9"
  operator_shape            = { "boot_volume_size" : 50, "memory" : 4, "ocpus" : 1, "shape" : "VM.Standard.E5.Flex" }
  operator_cloud_init = [
    {
      name         = "dockerinstall"
      content_type = "text/x-shellscript",
      content      = file("./data/operator-cloud-init.sh")
    }
  ]
  # Network variables
  create_vcn = var.create_vcn
  vcn_name   = var.vcn_name # Ignored if create_vcn = false

  # Cluster variables
  create_cluster          = var.create_cluster // *true/false
  cluster_name            = var.cluster_name
  cluster_type            = "enhanced"   // *basic/enhanced
  cni_type                = var.cni_type // *flannel/npn
  kubernetes_version      = var.kubernetes_version
  allow_worker_ssh_access = true

  worker_pools = {
    simple-np = {
      description = "Worker nodes for the OKE cluster.",
      size        = var.general_np_size
      os          = "Oracle Linux",
      os_version  = "8",
      image_type  = "oke",
      shape       = lookup(var.general_np_flex_shape, "instanceShape", "VM.Standard.E5.Flex"),
      ocpus       = lookup(var.general_np_flex_shape, "ocpus", 2),
      memory      = lookup(var.general_np_flex_shape, "memory", 16)
      node_metadata = {
        areLegacyImdsEndpointsDisabled = true
      }
    }
  }
  output_detail = true
}

module "litellm-install" {
  source          = "./modules/helm-litellm"
  depends_on      = [module.oke]
  litellm_install = true
  bastion_host    = module.oke.bastion_public_ip
  bastion_user    = var.bastion_user
  operator_host   = module.oke.operator_private_ip
  operator_user   = var.bastion_user
  ssh_private_key = tls_private_key.stack_key.private_key_openssh

  create_iam_resources       = local.create_iam_resources
  create_iam_operator_policy = local.create_iam_operator_policy

  litellm_release_name             = "litellm"
  litellm_helm_version             = "1.106.0"
  litellm_namespace                = "litellm"
  litellm_helm_values_files        = ["data/litellm-values.yaml"]
  litellm_helm_values              = {}
  litellm_postgresql_manifest_file = "data/litellm-postgresql.yaml"

  nvidia_api_key = var.nvidia_api_key
}

module "demoui-install" {
  source     = "./modules/deploy-demoui"
  depends_on = [module.oke, module.litellm-install]
  providers = {
    oci = oci
  }
  demoui_install    = true
  region            = var.region
  bastion_host      = module.oke.bastion_public_ip
  bastion_user      = var.bastion_user
  operator_host     = module.oke.operator_private_ip
  operator_user     = var.bastion_user
  ssh_private_key   = tls_private_key.stack_key.private_key_openssh
  demoui_cluster_id = module.oke.cluster_id

  ocir_username   = var.ocir_username
  ocir_auth_token = var.ocir_auth_token
  repositories = {
    demoui = {
      compartment_id                    = coalesce(var.compartment_id, var.compartment_ocid)
      container_repository_is_immutable = false
      container_repository_is_public    = false
      defined_tags                      = {}
      freeform_tags                     = {}
    }
  }
  demoui_release_name         = "demoui"
  demoui_namespace            = "litellm"
  demoui_repository_name      = "demoui"
  is_demoui_lb_public         = true
  demoui_load_balancer_nsg_id = module.oke.pub_lb_nsg_id
}

output "bastion" {
  value = "%{if var.create_bastion}${module.oke.bastion_public_ip}%{else}bastion host not created.%{endif}"
}

output "operator" {
  value = "%{if var.create_operator}${module.oke.operator_private_ip}%{else}operator host not created.%{endif}"
}

output "ssh_to_operator" {
  value = "%{if var.create_operator && var.create_bastion}${module.oke.ssh_to_operator}%{else}bastion and operator hosts not created.%{endif}"
}

output "demoui_access" {
  description = "Demo UI browser URL and public/private access instructions."
  value       = module.demoui-install.access_instructions
}
