# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
all:
  children:
    region_1:
      hosts:
        %{ for host in region_1_instances ~}
        %{ if lookup(host.freeform_tags, "role", "") == "drbd" }
        ${ host.hostname_label}:
          ansible_host: ${host.private_ip}
        %{ endif ~}
        %{ endfor ~}

    region_2:
      hosts:
        %{ for host in region_2_instances ~}
        %{ if lookup(host.freeform_tags, "role", "") == "drbd" }
        ${ host.hostname_label}:
          ansible_host: ${host.private_ip}
        %{ endif ~}
        %{ endfor ~}

    qnet_a:
      hosts:
        %{ for host in region_1_instances ~}
        %{ if lookup(host.freeform_tags, "role", "") == "qnet" }
        ${ host.hostname_label}:
          ansible_host: ${host.private_ip}
        %{ endif ~}
        %{ endfor ~}

    qnet_b:
      hosts:
        %{ for host in region_2_instances ~}
        %{ if lookup(host.freeform_tags, "role", "") == "qnet" }
        ${ host.hostname_label}:
          ansible_host: ${host.private_ip}
        %{ endif ~}
        %{ endfor ~}

    drbd_nodes:
      children:
        region_1: {}
        region_2: {}

    primary_drbd_nodes:
      hosts:
        %{ for host in region_1_instances ~}
        %{ if lookup(host.freeform_tags, "drbd_role", "") == "primary" }
        ${host.hostname_label}: {}
        %{ endif ~}
        %{ endfor ~}
        %{ for host in region_2_instances ~}
        %{ if lookup(host.freeform_tags, "drbd_role", "") == "primary" }
        ${host.hostname_label}: {}
        %{ endif ~}
        %{ endfor ~}

    pcs_nodes:
      children:
        region_1: {}
        region_2: {}

    primary_pcs_nodes:
      hosts:
        %{ for host in region_1_instances ~}
        %{ if lookup(host.freeform_tags, "pcs_role", "") == "primary" }
        ${host.hostname_label}: {}
        %{ endif ~}
        %{ endfor ~}
        %{ for host in region_2_instances ~}
        %{ if lookup(host.freeform_tags, "pcs_role", "") == "primary" }
        ${host.hostname_label}: {}
        %{ endif ~}
        %{ endfor ~}

    kvm_nodes:
      children:
        region_1: {}
        region_2: {}

    primary_kvm_nodes:
      hosts:
        %{ for host in region_1_instances ~}
        %{ if lookup(host.freeform_tags, "kvm_role", "") == "primary" }
        ${host.hostname_label}: {}
        %{ endif ~}
        %{ endfor ~}
        %{ for host in region_2_instances ~}
        %{ if lookup(host.freeform_tags, "kvm_role", "") == "primary" }
        ${host.hostname_label}: {}
        %{ endif ~}
        %{ endfor ~}
