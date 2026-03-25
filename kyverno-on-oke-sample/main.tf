# Copyright (c) 2022, 2024 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

module "oke" {
  source  = "oracle-terraform-modules/oke/oci"
  create_iam_operator_policy = "always"
  create_iam_resources = true

allow_rules_workers = {
    "Allow TCP ingress to workers for SSL traffic from anywhere" : {
      direction = "INGRESS", protocol = 6, port = 5443, source = "10.0.0.0/32", source_type = "CIDR_BLOCK",
    }
  }

  state_id = var.state_id
  providers = {
    oci.home = oci.home
  }
  tenancy_id                   = var.tenancy_ocid
  compartment_id               = coalesce(var.compartment_id, var.compartment_ocid)
  
  ssh_private_key = tls_private_key.stack_key.private_key_openssh
  ssh_public_key  = local.bundled_ssh_public_keys
  bastion_allowed_cidrs    = var.bastion_allowed_cidrs
  bastion_image_type       = var.bastion_image_type
  bastion_shape = { "boot_volume_size": 50, "memory": 4, "ocpus": 1, "shape": "VM.Standard.E5.Flex" }
  # Operator variables
  operator_image_type                = var.operator_image_type
  operator_shape = { "boot_volume_size": 50, "memory": 4, "ocpus": 1, "shape": "VM.Standard.E5.Flex" }
  # Network variables
  create_vcn               = var.create_vcn
  vcn_name                 = var.vcn_name   # Ignored if create_vcn = false

  # Cluster variables
  create_cluster              = var.create_cluster // *true/false
  cluster_name                = var.cluster_name
  cluster_type                = "enhanced"   // *basic/enhanced
  cni_type                    = var.cni_type // *flannel/npn
  kubernetes_version          = var.kubernetes_version
  allow_worker_ssh_access     = true
  
  worker_pools = {
    simple-np = {
      description = "Worker nodes for the OKE cluster.",
      size        = var.simple_np_size
      os          = "Oracle Linux",
      os_version  = "8",
      image_type  = "oke",
      shape       = lookup(var.simple_np_flex_shape, "instanceShape", "VM.Standard.E5.Flex"),
      ocpus       = lookup(var.simple_np_flex_shape, "ocpus", 2),
      memory      = lookup(var.simple_np_flex_shape, "memory", 12)
    }
  }
  output_detail = true
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