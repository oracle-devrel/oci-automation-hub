# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "local_file" "drbd_dns_config" {
  content = templatefile(format("%s/ansible/roles/pcs_primary/defaults/main.tpl", path.root), {
    dns_zone_id            = var.dns_zones[var.pcs_drbd_dns_details.dns_object_name].id
    dns_domain_name        = var.dns_zones[var.pcs_drbd_dns_details.dns_object_name].name
    dns_record_name        = var.pcs_drbd_dns_details.dns_record_name
    dns_region             = var.pcs_drbd_dns_details.dns_region
    dns_unregister_on_stop = var.pcs_drbd_dns_details.dns_unregister_on_stop
  })

  filename = format("%s/ansible/roles/pcs_primary/defaults/main.yml", path.root)
}

resource "local_file" "ansible_inventory" {
  content = templatefile(format("%s/ansible/inventory.tpl", path.root), {
    region_1_instances = var.instances_region1
    region_2_instances = var.instances_region2
  })

  filename = format("%s/ansible/inventory.yml", path.root)
}

locals {
  bastion_public_ip = one(toset([ for instance in merge(var.instances_region1, var.instances_region2): 
                            instance.public_ip if lookup(instance.freeform_tags, "role", "") == "bastion" ]))

  ansible_secret_vars = {
    linbit_username   = var.linbit_username
    linbit_password   = var.linbit_password
    linbit_cluster_id = var.linbit_cluster_id
    pcs_password      = var.pcs_password
  }
}

resource "null_resource" "send_to_bastion" {
  depends_on = [local_file.drbd_dns_config, local_file.ansible_inventory]

  provisioner "file" {
    content     = jsonencode(local.ansible_secret_vars)
    destination = "/tmp/ansible-secrets.json"

    connection {
      type        = "ssh"
      user        = "opc"
      host        = local.bastion_public_ip
      private_key = file(var.private_ssh_key_path)
      agent       = false
      timeout     = "100s"
    }
  }

  provisioner "local-exec" {
    command = format("zip -r %s/ansible.zip %s/ansible/", path.root, path.root)
  }

  provisioner "local-exec" {
    command = format("scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s %s/ansible.zip opc@%s:/tmp", var.private_ssh_key_path, path.root, local.bastion_public_ip)
  }

  provisioner "remote-exec" {
    inline = [ "chmod 600 /tmp/ansible-secrets.json", "sudo dnf install ansible-core -y",
              "cd /tmp", "unzip -o ansible.zip", "cd ansible",
              "ansible-galaxy collection install -r requirements.yml",
              "ansible-playbook playbooks/main.yml -i inventory.yml -e @/tmp/ansible-secrets.json" ]

    connection {
      type        = "ssh"
      user        = "opc"
      host        = local.bastion_public_ip
      private_key = file(var.private_ssh_key_path)
      agent       = false
      timeout     = "100s"
    }
  }
}
