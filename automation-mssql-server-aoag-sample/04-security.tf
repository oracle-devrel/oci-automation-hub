# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  dc_source_cidrs  = [var.vcn_cidr]
  sql_source_cidrs = [var.vcn_cidr]

  dc_tcp_ingress_rules = [
    { min = 53, max = 53, description = "DNS TCP" },
    { min = 88, max = 88, description = "Kerberos TCP" },
    { min = 135, max = 135, description = "RPC endpoint mapper TCP" },
    { min = 139, max = 139, description = "NetBIOS session TCP" },
    { min = 389, max = 389, description = "LDAP TCP" },
    { min = 445, max = 445, description = "SMB TCP" },
    { min = 464, max = 464, description = "Kerberos password change TCP" },
    { min = 636, max = 636, description = "LDAPS TCP" },
    { min = 3268, max = 3268, description = "Global Catalog TCP" },
    { min = 3269, max = 3269, description = "Global Catalog SSL TCP" },
    { min = 5985, max = 5985, description = "WinRM HTTP TCP inside lab" },
    { min = 5986, max = 5986, description = "WinRM HTTPS TCP inside lab" },
    { min = 49152, max = 65535, description = "Windows dynamic RPC TCP" }
  ]

  dc_udp_ingress_rules = [
    { min = 53, max = 53, description = "DNS UDP" },
    { min = 88, max = 88, description = "Kerberos UDP" },
    { min = 123, max = 123, description = "Windows Time UDP" },
    { min = 137, max = 137, description = "NetBIOS name UDP" },
    { min = 138, max = 138, description = "NetBIOS datagram UDP" },
    { min = 389, max = 389, description = "LDAP UDP" },
    { min = 464, max = 464, description = "Kerberos password change UDP" }
  ]

  sql_tcp_ingress_rules = [
    { min = 53, max = 53, description = "DNS TCP responses and domain operations" },
    { min = 88, max = 88, description = "Kerberos TCP" },
    { min = 135, max = 135, description = "RPC endpoint mapper TCP" },
    { min = 139, max = 139, description = "NetBIOS session TCP" },
    { min = 389, max = 389, description = "LDAP TCP" },
    { min = 445, max = 445, description = "SMB TCP for admin and file witness" },
    { min = 464, max = 464, description = "Kerberos password change TCP" },
    { min = 1433, max = 1433, description = "SQL Server and AG listener TCP" },
    { min = 3343, max = 3343, description = "WSFC cluster service TCP" },
    { min = 5022, max = 5022, description = "SQL Always On HADR endpoint TCP" },
    { min = 5985, max = 5985, description = "WinRM HTTP TCP inside lab" },
    { min = 5986, max = 5986, description = "WinRM HTTPS TCP inside lab" },
    { min = 49152, max = 65535, description = "Windows dynamic RPC TCP" }
  ]

  sql_udp_ingress_rules = [
    { min = 53, max = 53, description = "DNS UDP" },
    { min = 88, max = 88, description = "Kerberos UDP" },
    { min = 123, max = 123, description = "Windows Time UDP" },
    { min = 137, max = 137, description = "NetBIOS name UDP" },
    { min = 138, max = 138, description = "NetBIOS datagram UDP" },
    { min = 389, max = 389, description = "LDAP UDP" },
    { min = 464, max = 464, description = "Kerberos password change UDP" },
    { min = 1434, max = 1434, description = "SQL Browser UDP" },
    { min = 3343, max = 3343, description = "WSFC cluster service UDP" }
  ]

  dc_tcp_source_rules = flatten([
    for source in local.dc_source_cidrs : [
      for rule in local.dc_tcp_ingress_rules : merge(rule, { source = source })
    ]
  ])

  dc_udp_source_rules = flatten([
    for source in local.dc_source_cidrs : [
      for rule in local.dc_udp_ingress_rules : merge(rule, { source = source })
    ]
  ])

  sql_tcp_source_rules = flatten([
    for source in local.sql_source_cidrs : [
      for rule in local.sql_tcp_ingress_rules : merge(rule, { source = source })
    ]
  ])

  sql_udp_source_rules = flatten([
    for source in local.sql_source_cidrs : [
      for rule in local.sql_udp_ingress_rules : merge(rule, { source = source })
    ]
  ])
}

resource "oci_core_security_list" "dc" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.sql.id
  display_name   = "DC_SC_List"
  freeform_tags  = var.freeform_tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    description = "RDP from client public IPv4"
    source      = var.dc_rdp_source_cidr
    protocol    = "6"

    tcp_options {
      min = 3389
      max = 3389
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.dc_tcp_source_rules

    content {
      description = ingress_security_rules.value.description
      source      = ingress_security_rules.value.source
      protocol    = "6"

      tcp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.dc_udp_source_rules

    content {
      description = ingress_security_rules.value.description
      source      = ingress_security_rules.value.source
      protocol    = "17"

      udp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset(local.dc_source_cidrs)

    content {
      description = "ICMP from lab CIDR"
      source      = ingress_security_rules.value
      protocol    = "1"
    }
  }
}

resource "oci_core_security_list" "sql1" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.sql.id
  display_name   = "SQL1_SC_List"
  freeform_tags  = var.freeform_tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    description = "RDP from configured source"
    source      = var.sql_rdp_source_cidr
    protocol    = "6"

    tcp_options {
      min = 3389
      max = 3389
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.sql_tcp_source_rules

    content {
      description = ingress_security_rules.value.description
      source      = ingress_security_rules.value.source
      protocol    = "6"

      tcp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.sql_udp_source_rules

    content {
      description = ingress_security_rules.value.description
      source      = ingress_security_rules.value.source
      protocol    = "17"

      udp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset(local.sql_source_cidrs)

    content {
      description = "ICMP from lab CIDR"
      source      = ingress_security_rules.value
      protocol    = "1"
    }
  }
}

resource "oci_core_security_list" "sql2" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.sql.id
  display_name   = "SQL2_SC_List"
  freeform_tags  = var.freeform_tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    description = "RDP from configured source"
    source      = var.sql_rdp_source_cidr
    protocol    = "6"

    tcp_options {
      min = 3389
      max = 3389
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.sql_tcp_source_rules

    content {
      description = ingress_security_rules.value.description
      source      = ingress_security_rules.value.source
      protocol    = "6"

      tcp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.sql_udp_source_rules

    content {
      description = ingress_security_rules.value.description
      source      = ingress_security_rules.value.source
      protocol    = "17"

      udp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset(local.sql_source_cidrs)

    content {
      description = "ICMP from lab CIDR"
      source      = ingress_security_rules.value
      protocol    = "1"
    }
  }
}
