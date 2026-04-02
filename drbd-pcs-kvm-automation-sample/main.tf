# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# Generate SSH keys for the project
resource "tls_private_key" "stack_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key_file" {
  filename = "${path.root}/id_rsa"
  content  = tls_private_key.stack_key.private_key_openssh
}

terraform {
  required_providers {
    oci = {
      source  = "hashicorp/oci"
      version = "7.25.0"
    }
  }
}

provider "oci" {
  region           = var.region1
  alias            = "region1"
}

provider "oci" {
  region           = var.region2
  alias            = "region2"
}

module "network_region1" {
  source                = "./modules/network"
  vcn_params            = var.vcn_params_region1
  compartment_id        = var.compartment_ocid
  igw_params            = var.igw_params_region1
  ngw_params            = var.ngw_params_region1
  sgw_params            = var.sgw_params_region1
  rt_params             = var.rt_params_region1
  sl_params             = var.sl_params_region1
  subnet_params         = var.subnet_params_region1
  drg_params            = var.drg_params_region1
  drg_attachment_params = var.drg_attachment_params_region1

  providers = {
    oci = oci.region1
  }
}

module "network_region2" {
  source                = "./modules/network"
  vcn_params            = var.vcn_params_region2
  compartment_id        = var.compartment_ocid
  igw_params            = var.igw_params_region2
  ngw_params            = var.ngw_params_region2
  sgw_params            = var.sgw_params_region2
  rt_params             = var.rt_params_region2
  sl_params             = var.sl_params_region2
  subnet_params         = var.subnet_params_region2
  drg_params            = var.drg_params_region2
  drg_attachment_params = var.drg_attachment_params_region2

  providers = {
    oci = oci.region2
  }
}

# Peer the 2 VCNs
module "vcn_remote_peering" {
  source           = "./modules/remote-peering"
  compartment_id   = var.compartment_ocid
  drg_ids          = merge(module.network_region1.drgs, module.network_region2.drgs)
  requestor_params = var.requestor_params
  requestor_region = var.region1
  acceptor_params  = var.acceptor_params
  acceptor_region  = var.region2

  providers = {
    oci.requestor = oci.region1
    oci.acceptor  = oci.region2
  }
}

# DNS Region 1
module "dns_region1" {
  depends_on          = [ module.vcn_remote_peering ]
  source              = "./modules/dns"
  compartment_id      = var.compartment_ocid
  dns_params          = var.dns_params_region1

  providers = {
    oci = oci.region1
  }
}

# Instances region1
module "instances_region1" {
  source              = "./modules/instances"
  compartment_id      = var.compartment_ocid
  subnet_ids          = module.network_region1.subnets_ids
  instance_params     = var.instance_params_region1
  bv_params           = var.bv_params_region1
  linux_images        = var.linux_images
  region              = var.region1
  ssh_public_key      = tls_private_key.stack_key.public_key_openssh

  providers = {
    oci = oci.region1
  }
}

# Instances region2
module "instances_region2" {
  source              = "./modules/instances"
  compartment_id      = var.compartment_ocid
  subnet_ids          = module.network_region2.subnets_ids
  instance_params     = var.instance_params_region2
  bv_params           = var.bv_params_region2
  linux_images        = var.linux_images
  region              = var.region2
  ssh_public_key      = tls_private_key.stack_key.public_key_openssh

  providers = {
    oci = oci.region2
  }
}

module "ansible_run" {
  depends_on           = [ module.instances_region1, module.instances_region2 ]
  source               = "./modules/ansible"
  instances_region1    = module.instances_region1.instances_full_details
  instances_region2    = module.instances_region2.instances_full_details
  private_ssh_key_path = local_sensitive_file.private_key_file.filename
  dns_zones            = module.dns_region1.dns_zones
  pcs_drbd_dns_details = var.pcs_drbd_dns_details
  linbit_username      = var.linbit_username
  linbit_password      = var.linbit_password
  linbit_cluster_id    = var.linbit_cluster_id
  pcs_password         = var.pcs_password
}
