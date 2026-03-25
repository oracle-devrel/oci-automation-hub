# Copyright (c) 2022, 2024 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

resource "null_resource" "helm_deployment_via_operator" {
  count = var.deploy_from_operator ? 1 : 0

  triggers = {
    manifest_md5    = try(md5("${var.helm_template_values_override}-${var.helm_user_values_override}"), null)
    deployment_name = var.deployment_name
    namespace       = var.namespace
    bastion_host    = var.bastion_host
    bastion_user    = var.bastion_user
    ssh_private_key = var.ssh_private_key
    operator_host   = var.operator_host
    operator_user   = var.operator_user
  }

  connection {
    bastion_host        = self.triggers.bastion_host
    bastion_user        = self.triggers.bastion_user
    bastion_private_key = self.triggers.ssh_private_key
    host                = self.triggers.operator_host
    user                = self.triggers.operator_user
    private_key         = self.triggers.ssh_private_key
    timeout             = "40m"
    type                = "ssh"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ${var.operator_helm_values_path}",
      "mkdir -p /home/${var.operator_user}/${var.deployment_name}"
    ]
  }
  
  provisioner "file" {
    source     = "kyverno-yaml/"
    destination = "/home/${var.operator_user}/${var.deployment_name}"
  }
  
  provisioner "remote-exec" {
    inline = [
      "helm repo add kyverno https://kyverno.github.io/kyverno/",
      "helm repo update",
      "helm install kyverno kyverno/kyverno -n kyverno --create-namespace"
      ]
  }

  lifecycle {
    ignore_changes = [
      triggers["namespace"],
      triggers["deployment_name"],
      triggers["bastion_host"],
      triggers["bastion_user"],
      triggers["ssh_private_key"],
      triggers["operator_host"],
      triggers["operator_user"]
    ]
  }
}
