# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_network_security_group" "api_endpoint_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "api_endpoint_nsg"
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_1" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Kubernetes worker to Kubernetes API endpoint communication"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.nodepool_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_2" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Kubernetes worker to Kubernetes API endpoint communication"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.nodepool_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_3" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Pod to Kubernetes API endpoint communication (when using VCN-native pod networking)"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.pods_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_4" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Pod to Kubernetes API endpoint communication (when using VCN-native pod networking)"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.pods_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_5" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Path Discovery"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = var.nodepool_subnet_cidr
  protocol                  = "1" #icmp
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_6" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Client access to Kubernetes API endpoint"
  direction                 = "INGRESS"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_7" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Allow Kubernetes API endpoint to communicate with OKE"
  direction                 = "EGRESS"
  destination_type          = "SERVICE_CIDR_BLOCK"
  destination               = data.oci_core_services.test_services.services[0]["cidr_block"]
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_8" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "All traffic to worker nodes (when using flannel for pod networking)"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.nodepool_subnet_cidr
  protocol                  = "6" #TCP
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_9" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Kubernetes API endpoint to pod communication (when using VCN-native pod networking)"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.pods_subnet_cidr
  protocol                  = "all"
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_10" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Path Discovery"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.nodepool_subnet_cidr
  protocol                  = "1" #icmp
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_11" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Kubernetes API endpoint to worker node communication (when using VCN-native pod networking)"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.nodepool_subnet_cidr
  protocol                  = "1" #icmp
  # icmp_options {
  #   type = 3
  #   code = 4
  # }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_nsg_rule_12" {
  network_security_group_id = oci_core_network_security_group.api_endpoint_nsg.id
  description               = "Kubernetes API endpoint to worker node communication (when using VCN-native pod networking)"
  direction                 = "EGRESS"
  destination_type          = "CIDR_BLOCK"
  destination               = var.nodepool_subnet_cidr
  protocol                  = "6" #TCP
  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}
