# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  user_public_ssh_key     = chomp(var.ssh_public_key)
  bundled_ssh_public_keys = "${local.user_public_ssh_key}\n${chomp(tls_private_key.stack_key.public_key_openssh)}"
}
resource "tls_private_key" "stack_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}