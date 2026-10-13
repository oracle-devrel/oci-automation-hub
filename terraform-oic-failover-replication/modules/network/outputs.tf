output "vcn_id" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.this.id
}

output "public_subnet_id" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "functions_subnet_id" {
  description = "OCID of the private subnet for OCI Functions."
  value       = try(oci_core_subnet.functions[0].id, null)
}

output "internet_gateway_id" {
  description = "OCID of the internet gateway."
  value       = oci_core_internet_gateway.this.id
}

output "nat_gateway_id" {
  description = "OCID of the NAT gateway."
  value       = oci_core_nat_gateway.this.id
}
