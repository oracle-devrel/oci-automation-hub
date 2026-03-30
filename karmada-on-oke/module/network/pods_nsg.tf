# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_network_security_group" "pods_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "pods_nsg"
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_11" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Kubernetes API endpoint to pod communication (when using VCN-native pod networking)"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.api_endpoint_subnet_cidr
  protocol                  = "all" #all
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_2" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Allow pods on one worker node to communicate with pods on other worker nodes"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.nodepool_subnet_cidr
  protocol                  = "all" #all
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_3" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Allow pods to communicate with each other"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.pods_subnet_cidr
  protocol                  = "all" #all
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_4" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Allow pods to communicate with each other"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.pods_subnet_cidr
  protocol                  = "all" #all
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_5" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Path Discovery"
  direction                 = "EGRESS"
  destination_type          = "SERVICE_CIDR_BLOCK"
  destination               = data.oci_core_services.test_services.services[0]["cidr_block"]
  protocol                  = "1" #icmp
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_6" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Allow worker nodes to communicate with OCI services"
  direction                 = "EGRESS"
  destination_type          = "SERVICE_CIDR_BLOCK"
  destination               = data.oci_core_services.test_services.services[0]["cidr_block"]
  protocol                  = "6" #tcp
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_7" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Pod to Kubernetes API endpoint communication (when using VCN-native pod networking)"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.api_endpoint_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_8" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "Pod to Kubernetes API endpoint communication (when using VCN-native pod networking)"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.api_endpoint_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "pods_nsg_rule_9" {
  network_security_group_id = oci_core_network_security_group.pods_nsg.id
  description               = "(optional) Allow pods to communicate with internet"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
  protocol                  = "6" #TCP
}