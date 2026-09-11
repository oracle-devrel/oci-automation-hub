# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# Copy this file to a local .pkrvars.hcl file and fill in the environment-specific values.
# Do not commit private keys or other secrets.

base_image_ocid = "REPLACE_WITH_OKE_WORKER_IMAGE_OCID"
base_image_name = "Oracle-Linux-8.10-YYYY.MM.DD-0-OKE-1.35.x-xxxx"

region              = "us-ashburn-1"
oci_profile         = "DEFAULT"
compartment_ocid    = "REPLACE_WITH_COMPARTMENT_OCID"
availability_domain = "REPLACE_WITH_AD_NAME"
subnet_ocid         = "REPLACE_WITH_IMAGE_BUILDER_SUBNET_OCID"

image_name         = "oke-optimized-ol8-oke-1-35-2-fast-start-packer"
kubernetes_version = "v1.35.2"

shape                   = "VM.Standard.E5.Flex"
ocpus                   = 4
memory_in_gbs           = 16
boot_volume_size_in_gbs = 50
assign_public_ip        = true
ssh_public_key_path     = "/absolute/path/to/id_rsa.pub"
ssh_private_key_path    = "/absolute/path/to/id_rsa"
optimization_profile    = "fast-start"
skip_create_image       = false

prepull_images = [
  "iad.ocir.io/axoxdievda5j/oke-public-pause@sha256:6e287874898efea60adff9dc1faaee355740b192763f963fe66cf755d995cf32",
  "iad.ocir.io/id9y6mi8tcky/oke-public-vcn-native-ip-cni-plugin@sha256:916f9953b84f2788b410c45ba766901e99d9c345d37e2fc35a16c312f27e34f0",
  "iad.ocir.io/id9y6mi8tcky/oke-public-kube-proxy@sha256:175559244baa3cbee68adfc1357c18871406c7a2d49dd487d2f04e111e7931a0"
]

extra_image_tags = {
  BuildTool = "packer"
}
