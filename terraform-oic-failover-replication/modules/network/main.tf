resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-internet-gateway"
  enabled        = true
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nat-gateway"
}

resource "oci_core_default_route_table" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_route_table_id
  display_name               = "${var.name_prefix}-default-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
    description       = "Route internet-bound traffic through the internet gateway."
  }

  dynamic "route_rules" {
    for_each = var.oic_host_ipv4 == "" ? [] : [var.oic_host_ipv4]

    content {
      destination       = "${route_rules.value}/32"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_nat_gateway.this.id
      description       = "Route traffic for the primary OIC host through the NAT gateway."
    }
  }
}

resource "oci_core_route_table" "functions" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-functions-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
    description       = "Route OCI Functions outbound traffic through the NAT gateway."
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.name_prefix}-public-subnet"
  route_table_id             = oci_core_vcn.this.default_route_table_id
  security_list_ids          = [oci_core_vcn.this.default_security_list_id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "functions" {
  count                      = var.create_functions_subnet ? 1 : 0
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.functions_subnet_cidr
  display_name               = "${var.name_prefix}-functions-subnet"
  route_table_id             = oci_core_route_table.functions.id
  security_list_ids          = [oci_core_vcn.this.default_security_list_id]
  prohibit_public_ip_on_vnic = true
}
