# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# roles/pcs_primary/defaults/main.yml
pcs_drbd_resource_name: drbd_r0
drbd_promoted_max: 1
drbd_promoted_node_max: 1
fs_drbd_resource_name: fs_drbd
drbd_dns_resource_name: dns
drbd_dns_record_name: primary
drbd_dns_scope: PRIVATE
drbd_dns_zone_id: ${dns_zone_id}
drbd_dns_domain_name: ${dns_domain_name}
drbd_dns_record_name: ${dns_record_name}
drbd_dns_region: ${dns_region}
drbd_dns_unregister_on_stop: ${dns_unregister_on_stop}
pcs_kvm_resource_name: p_virtdom_fedora
kvm_config: /etc/libvirt/qemu/demovm.xml
