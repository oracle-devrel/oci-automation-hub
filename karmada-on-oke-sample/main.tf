# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

module "network" {
  source                   = "./modules/network"
  compartment_ocid         = var.compartment_ocid
  lb_subnet_cidr           = var.lb_subnet_cidr
  pods_subnet_cidr         = var.pods_subnet_cidr
  cidr_blocks              = var.cidr_blocks
  vcn_display_name         = var.vcn_display_name
  api_endpoint_subnet_cidr = var.api_endpoint_subnet_cidr
  nodepool_subnet_cidr     = var.nodepool_subnet_cidr

}

module "network1" {
  source                   = "./modules/network"
  compartment_ocid         = var.compartment_ocid
  lb_subnet_cidr           = var.lb_subnet_cidr
  pods_subnet_cidr         = var.pods_subnet_cidr
  cidr_blocks              = var.cidr_blocks
  vcn_display_name         = "network1"
  api_endpoint_subnet_cidr = var.api_endpoint_subnet_cidr
  nodepool_subnet_cidr     = var.nodepool_subnet_cidr

}

module "network2" {
  source                   = "./modules/network"
  compartment_ocid         = var.compartment_ocid
  lb_subnet_cidr           = var.lb_subnet_cidr
  pods_subnet_cidr         = var.pods_subnet_cidr
  cidr_blocks              = var.cidr_blocks
  vcn_display_name         = "network2"
  api_endpoint_subnet_cidr = var.api_endpoint_subnet_cidr
  nodepool_subnet_cidr     = var.nodepool_subnet_cidr

}

resource "oci_containerengine_cluster" "oke" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = "v1.34.2"
  name               = "k"
  vcn_id             = module.network.vcn_id
  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = module.network.api_endpoint_subnet_id
    nsg_ids              = module.network.api_endpoint_nsg_ids
  }
  options {
    service_lb_subnet_ids = module.network.service_lb_subnet_ids
  }
  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }
}

resource "oci_containerengine_cluster" "oke1" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = "v1.34.2"
  name               = "k1"
  vcn_id             = module.network1.vcn_id
  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = module.network1.api_endpoint_subnet_id
    nsg_ids              = module.network1.api_endpoint_nsg_ids
  }
  options {
    service_lb_subnet_ids = module.network1.service_lb_subnet_ids
  }
  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }
}

resource "oci_containerengine_cluster" "oke2" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = "v1.34.2"
  name               = "k2"
  vcn_id             = module.network2.vcn_id
  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = module.network2.api_endpoint_subnet_id
    nsg_ids              = module.network2.api_endpoint_nsg_ids
  }
  options {
    service_lb_subnet_ids = module.network2.service_lb_subnet_ids
  }
  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }
}

resource "oci_containerengine_node_pool" "oke-pool" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.oke.id
  name               = "oke-pool"
  node_shape         = "VM.Standard.E5.Flex"
  kubernetes_version = "v1.34.2"
  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = module.network.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[1].name
      subnet_id           = module.network.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[2].name
      subnet_id           = module.network.node_pool_subnet_id
    }
    size    = 3
    nsg_ids = module.network.nodepool_nsg_ids
    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = 31
      pod_nsg_ids       = module.network.nodepool_nsg_ids
      pod_subnet_ids    = [module.network.node_pool_subnet_id]
    }
  }
  node_source_details {
    source_type = "IMAGE"
    image_id    = local.image_id
  }
  node_shape_config {
    memory_in_gbs = "16"
    ocpus         = 1
  }
}


resource "oci_containerengine_node_pool" "oke-pool1" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.oke1.id
  name               = "oke-pool"
  node_shape         = "VM.Standard.E5.Flex"
  kubernetes_version = "v1.34.2"
  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = module.network1.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[1].name
      subnet_id           = module.network1.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[2].name
      subnet_id           = module.network1.node_pool_subnet_id
    }
    size    = 1
    nsg_ids = module.network1.nodepool_nsg_ids
    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = 31
      pod_nsg_ids       = module.network1.nodepool_nsg_ids
      pod_subnet_ids    = [module.network1.node_pool_subnet_id]
    }
  }
  node_source_details {
    source_type = "IMAGE"
    image_id    = local.image_id
  }
  node_shape_config {
    memory_in_gbs = "16"
    ocpus         = 1
  }
}

resource "oci_containerengine_node_pool" "oke-pool2" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.oke2.id
  name               = "oke-pool"
  node_shape         = "VM.Standard.E5.Flex"
  kubernetes_version = "v1.34.2"
  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = module.network2.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[1].name
      subnet_id           = module.network2.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[2].name
      subnet_id           = module.network2.node_pool_subnet_id
    }
    size    = 1
    nsg_ids = module.network2.nodepool_nsg_ids
    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = 31
      pod_nsg_ids       = module.network2.nodepool_nsg_ids
      pod_subnet_ids    = [module.network2.node_pool_subnet_id]
    }
  }
  node_source_details {
    source_type = "IMAGE"
    image_id    = local.image_id
  }
  node_shape_config {
    memory_in_gbs = "16"
    ocpus         = 1
  }
}


data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_containerengine_node_pool_option" "test_node_pool_option" {
  node_pool_option_id = "all"
}

data "oci_core_images" "shape_specific_images" {
  #Required
  compartment_id = var.tenancy_ocid
  shape          = "VM.Standard.E5.Flex"
}


data "oci_containerengine_node_pool_option" "node_pool_options" {
  compartment_id     = var.compartment_ocid
  node_pool_option_id = oci_containerengine_cluster.oke.id
}

#Oracle-Linux-8.10-2025.06.17-0-OKE-1.32.1-878
locals {
  all_images  = data.oci_core_images.shape_specific_images.images
  all_sources = data.oci_containerengine_node_pool_option.test_node_pool_option.sources
  #compartment_images = [for image in local.all_images : image.id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*.*OKE-1.32.1*", image.display_name)) > 0]
  #compartment_images = [for image in local.all_images : image.id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*", image.display_name)) > 0]
  #oracle_linux_images = [for source in local.all_sources : source.image_id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*.*OKE-1.32.1*", source.source_name)) > 0]
  compartment_images = [for image in local.all_images : image.id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*", image.display_name)) > 0]
  oracle_linux_images = [for source in local.all_sources : source.image_id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*", source.source_name)) > 0]
  #image_id = tolist(setintersection(toset(local.compartment_images), toset(local.oracle_linux_images)))[0]
  #image_id = data.oci_containerengine_node_pool_option.node_pool_options.sources[0].image_id

  kubernetes_version = "1.34.2"
  linux_version = "8"
  # image_id = element([for source in data.oci_containerengine_node_pool_option.node_pool_options.sources :
  #   source.image_id if length(regexall("(${local.linux_version}\\.\\d*)-aarch64-([\\.0-9]+)-\\d-", source.source_name)) > 0 &&
  #   length(regexall(trim("${local.kubernetes_version}", "v"), source.source_name)) > 0], 0)
  image_id = element([for source in data.oci_containerengine_node_pool_option.node_pool_options.sources :
    source.image_id if length(regexall("^Oracle-Linux-${local.linux_version}\\.\\d*-20.*-OKE-${local.kubernetes_version}-",source.source_name)) > 0  ], 0)

  cluster_id1 = oci_containerengine_cluster.oke1.id
  cluster_id2 = oci_containerengine_cluster.oke2.id
}

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = 1
}

data "oci_core_images" "image" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = 9
  shape                    = "VM.Standard.E5.Flex"
}

resource "oci_core_instance" "karmada_vm" {
  depends_on          = [oci_containerengine_node_pool.oke-pool, oci_containerengine_node_pool.oke-pool1, oci_containerengine_node_pool.oke-pool2]
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domain.ad.name
  shape               = "VM.Standard.E5.Flex"
  display_name        = "k-vm"
  extended_metadata = {
    cluster_id = oci_containerengine_cluster.oke.id
    cluster_id1 = oci_containerengine_cluster.oke1.id
    cluster_id2 = oci_containerengine_cluster.oke2.id
  }
  create_vnic_details {
    subnet_id = module.network.api_endpoint_subnet_id
  }
  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.image.images[0].id
  }
  shape_config {
    ocpus         = 2
    memory_in_gbs = 16
  }
  metadata = {
    ssh_authorized_keys = local.bundled_ssh_public_keys
    user_data           = base64encode(file("cloud-init.sh"))
  }
}

resource "oci_core_vnic_attachment" "karmada" {
  #Required
  create_vnic_details {
    #Required
    subnet_id = module.network.node_pool_subnet_id
    display_name     = "karmada-vm"
    assign_public_ip = "false"
    hostname_label = "karmada-vm"
    nsg_ids        = []
  }
  instance_id = oci_core_instance.karmada_vm.id
}

data "oci_core_images" "OL9_images" {
  compartment_id           = var.compartment_ocid
  shape                    = "VM.Standard.E5.Flex"
  operating_system         = "Oracle Linux"
  operating_system_version = 9
}


resource "null_resource" "k-vm" {
  depends_on = [oci_containerengine_cluster.oke, oci_core_instance.karmada_vm]
  connection {
    type        = "ssh"
    host        = oci_core_instance.karmada_vm.public_ip
    user        = "opc"
    private_key = tls_private_key.stack_key.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = [
      "sudo /usr/bin/curl -s https://raw.githubusercontent.com/karmada-io/karmada/master/hack/install-cli.sh | sudo /bin/bash",
         
    ]
  }
}