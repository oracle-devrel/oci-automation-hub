# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

packer {
  required_plugins {
    oracle = {
      source  = "github.com/hashicorp/oracle"
      version = ">= 1.1.2"
    }
  }
}

variable "base_image_ocid" {
  type        = string
  description = "OCID of the Oracle-published OKE worker image to optimize."
}

variable "base_image_name" {
  type        = string
  description = "Display name of the base OKE worker image. Used only for image tags and the build manifest."
  default     = "unknown"
}

variable "image_name" {
  type        = string
  description = "Display name for the resulting optimized custom image. If empty, a timestamped name is generated."
  default     = ""
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment where the temporary Packer builder instance runs."
}

variable "image_compartment_ocid" {
  type        = string
  description = "Compartment where the optimized image is created. Defaults to compartment_ocid when empty."
  default     = ""
}

variable "availability_domain" {
  type        = string
  description = "Availability domain where the temporary builder instance runs, for example Uocm:US-ASHBURN-AD-1."
}

variable "subnet_ocid" {
  type        = string
  description = "Subnet OCID for the temporary builder instance. It must allow SSH from the Packer host."
}

variable "region" {
  type        = string
  description = "OCI region."
  default     = "us-ashburn-1"
}

variable "oci_profile" {
  type        = string
  description = "OCI config profile used by the Packer Oracle builder."
  default     = "DEFAULT"
}

variable "shape" {
  type        = string
  description = "Builder instance shape."
  default     = "VM.Standard.E5.Flex"
}

variable "ocpus" {
  type        = number
  description = "Builder instance OCPUs for flexible shapes."
  default     = 4
}

variable "memory_in_gbs" {
  type        = number
  description = "Builder instance memory for flexible shapes."
  default     = 16
}

variable "boot_volume_size_in_gbs" {
  type        = number
  description = "Builder boot volume size. OCI requires at least 50 GB."
  default     = 50
}

variable "assign_public_ip" {
  type        = bool
  description = "Assign a public IP to the temporary builder VNIC. Set false only if Packer can SSH over private networking."
  default     = true
}

variable "ssh_username" {
  type        = string
  description = "SSH user for the OKE worker image."
  default     = "opc"
}

variable "ssh_public_key_path" {
  type        = string
  description = "SSH public key injected into the temporary builder instance."
}

variable "ssh_private_key_path" {
  type        = string
  description = "SSH private key used by Packer to connect to the temporary builder instance."
}

variable "kubernetes_version" {
  type        = string
  description = "Target OKE Kubernetes version for image tagging."
  default     = "v1.35.2"
}

variable "optimization_profile" {
  type        = string
  description = "Optimization profile tag value."
  default     = "fast-start"
}

variable "project_name" {
  type        = string
  description = "Project tag value."
  default     = "OKEOptimization"
}

variable "skip_create_image" {
  type        = bool
  description = "Set true for build-script testing without creating a custom image."
  default     = false
}

variable "prepull_images" {
  type        = list(string)
  description = "OCI/OKE images to pre-pull into CRI-O storage during image build. Use digest-pinned, region-correct references."
  default = [
    "iad.ocir.io/axoxdievda5j/oke-public-pause@sha256:6e287874898efea60adff9dc1faaee355740b192763f963fe66cf755d995cf32",
    "iad.ocir.io/id9y6mi8tcky/oke-public-vcn-native-ip-cni-plugin@sha256:916f9953b84f2788b410c45ba766901e99d9c345d37e2fc35a16c312f27e34f0",
    "iad.ocir.io/id9y6mi8tcky/oke-public-kube-proxy@sha256:175559244baa3cbee68adfc1357c18871406c7a2d49dd487d2f04e111e7931a0"
  ]
}

variable "extra_image_tags" {
  type        = map(string)
  description = "Additional freeform tags to place on the resulting optimized image."
  default     = {}
}

locals {
  generated_image_name       = "oke-optimized-ol8-${replace(trimprefix(var.kubernetes_version, "v"), ".", "-")}-${var.optimization_profile}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  image_name                 = var.image_name != "" ? var.image_name : local.generated_image_name
  image_compartment_ocid     = var.image_compartment_ocid != "" ? var.image_compartment_ocid : var.compartment_ocid
  prepull_images_fingerprint = sha256(jsonencode(var.prepull_images))

  common_tags = {
    ManagedBy             = "packer"
    Project               = var.project_name
    k8s_version           = var.kubernetes_version
    base_image_ocid       = var.base_image_ocid
    base_image_name       = var.base_image_name
    optimization_profile  = var.optimization_profile
    prepull_images_sha256 = local.prepull_images_fingerprint
  }
}

source "oracle-oci" "oke_optimized_worker" {
  access_cfg_file_account = var.oci_profile
  region                  = var.region

  availability_domain    = var.availability_domain
  base_image_ocid        = var.base_image_ocid
  compartment_ocid       = var.compartment_ocid
  image_compartment_ocid = local.image_compartment_ocid
  image_name             = local.image_name
  instance_name          = "${local.image_name}-builder"

  shape = var.shape
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  disk_size = var.boot_volume_size_in_gbs

  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_path
  subnet_ocid          = var.subnet_ocid

  create_vnic_details {
    assign_public_ip = var.assign_public_ip
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }

  instance_options_are_legacy_imds_endpoints_disabled = true
  skip_create_image                                   = var.skip_create_image

  instance_tags = merge(local.common_tags, {
    Role = "packer-image-builder"
  })

  tags = merge(local.common_tags, var.extra_image_tags)
}

build {
  name    = "oke-optimized-worker"
  sources = ["source.oracle-oci.oke_optimized_worker"]

  provisioner "shell" {
    environment_vars = [
      "BASE_IMAGE_OCID=${var.base_image_ocid}",
      "BASE_IMAGE_NAME=${var.base_image_name}",
      "KUBERNETES_VERSION=${var.kubernetes_version}",
      "OPTIMIZATION_PROFILE=${var.optimization_profile}",
      "PREPULL_IMAGES=${join(" ", var.prepull_images)}"
    ]
    pause_before = "10s"
    script       = "${path.root}/scripts/optimize-oke-worker.sh"
  }
}
