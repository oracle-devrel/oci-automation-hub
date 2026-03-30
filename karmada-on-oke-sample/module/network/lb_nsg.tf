# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_network_security_group" "lb_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "lb_nsg"
}

resource "oci_core_network_security_group_security_rule" "lb_nsg_rule_1" {
  network_security_group_id = oci_core_network_security_group.lb_nsg.id
  description               = "Allow inbound traffic to Load Balancer"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_nsg_rule_2" {
  network_security_group_id = oci_core_network_security_group.lb_nsg.id
  description               = "Allow traffic to worker nodes"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_nsg_rule_3" {
  network_security_group_id = oci_core_network_security_group.lb_nsg.id
  description               = "Allow OCI load balancer to communicate with kube-proxy on worker nodes"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.nodepool_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}
