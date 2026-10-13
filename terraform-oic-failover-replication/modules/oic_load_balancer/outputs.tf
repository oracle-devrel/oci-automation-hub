output "id" {
  description = "OCID of the public regional load balancer."
  value       = oci_load_balancer_load_balancer.this.id
}

output "public_ip_address" {
  description = "Public IPv4 address assigned to the load balancer."
  value = one([
    for address in oci_load_balancer_load_balancer.this.ip_address_details :
    address.ip_address if address.is_public
  ])
}
