# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "terraform_data" "image_builder_recipe" {
  triggers_replace = {
    base_image_id       = local.worker_image_id
    build_script_sha    = filesha256("${path.module}/templates/image-builder-cloud-init.sh.tftpl")
    prepull_images_hash = sha256(jsonencode(var.prepull_images))
  }
}

resource "oci_core_instance" "image_builder" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.project_compartment_ocid
  display_name        = "${var.name}-image-builder"
  freeform_tags       = merge(local.common_tags, { Role = "image-builder" })
  shape               = var.image_builder_shape

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${var.name}-image-builder"
    hostname_label   = "imagebuilder"
    subnet_id        = oci_core_subnet.image_builder.id
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/templates/image-builder-cloud-init.sh.tftpl", {
      prepull_images = var.prepull_images
    }))
  }

  shape_config {
    memory_in_gbs = var.image_builder_memory_in_gbs
    ocpus         = var.image_builder_ocpus
  }

  source_details {
    boot_volume_size_in_gbs = var.worker_boot_volume_size_in_gbs
    source_id               = local.worker_image_id
    source_type             = "image"
  }

  preserve_boot_volume = false

  lifecycle {
    replace_triggered_by = [terraform_data.image_builder_recipe]
  }
}

resource "terraform_data" "image_builder_ready" {
  triggers_replace = {
    instance_id = oci_core_instance.image_builder.id
    recipe_id   = terraform_data.image_builder_recipe.id
  }

  connection {
    host        = oci_core_instance.image_builder.public_ip
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "45m"
    type        = "ssh"
    user        = "opc"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "for i in $(seq 1 180); do if sudo test -f /var/lib/oke-optimization/image-build-complete; then sudo tail -n 120 /var/log/oke-optimized-image-build.log || true; exit 0; fi; sleep 10; done",
      "sudo tail -n 200 /var/log/oke-optimized-image-build.log || true",
      "echo 'Timed out waiting for optimized OKE image build marker.'",
      "exit 1"
    ]
  }
}

resource "terraform_data" "image_builder_stopped" {
  triggers_replace = {
    instance_id = oci_core_instance.image_builder.id
    ready_id    = terraform_data.image_builder_ready.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      oci compute instance action \
        --instance-id '${oci_core_instance.image_builder.id}' \
        --action SOFTSTOP \
        --profile '${var.config_file_profile}' \
        --region '${var.region}' >/dev/null

      for i in $(seq 1 120); do
        state=$(oci compute instance get \
          --instance-id '${oci_core_instance.image_builder.id}' \
          --profile '${var.config_file_profile}' \
          --region '${var.region}' \
          --query 'data."lifecycle-state"' \
          --raw-output)

        if [ "$state" = "STOPPED" ]; then
          exit 0
        fi

        sleep 10
      done

      echo "Timed out waiting for image builder instance to stop."
      exit 1
    EOT
  }
}

resource "oci_core_image" "optimized_oke_worker" {
  compartment_id = var.project_compartment_ocid
  display_name   = local.optimized_worker_image_display_name
  freeform_tags  = local.optimized_worker_image_tags
  instance_id    = oci_core_instance.image_builder.id

  depends_on = [terraform_data.image_builder_stopped]

  timeouts {
    create = "2h"
    delete = "2h"
  }
}
