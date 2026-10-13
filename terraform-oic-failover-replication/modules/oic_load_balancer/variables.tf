variable "compartment_id" {
  description = "OCI compartment in which to create the load balancer."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet OCID for the load balancer."
  type        = string
}

variable "vcn_id" {
  description = "VCN OCID that contains the load balancer subnet."
  type        = string
}

variable "backend_ip_address" {
  description = "IPv4 address of the regional OIC endpoint."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for load balancer resource names."
  type        = string
}

variable "listener_certificate_id" {
  description = "OCID of the OCI Certificates service certificate used by the HTTPS listener."
  type        = string
}

variable "backend_server_certificate_pem" {
  description = "PEM-encoded server certificate presented by this regional OIC endpoint."
  type        = string
}

variable "backend_ca_certificate_pem" {
  description = "PEM-encoded CA certificate chain presented by this regional OIC endpoint."
  type        = string
}

variable "defined_tags" {
  description = "Defined tags applied to the load balancer and network security group."
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags applied to the load balancer and network security group."
  type        = map(string)
  default     = {}
}
