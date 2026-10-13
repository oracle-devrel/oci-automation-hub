variable "compartment_id" {
  description = "OCI compartment in which to create the VCN resources."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for resource display names."
  type        = string
}

variable "vcn_cidr" {
  description = "IPv4 CIDR block for the VCN."
  type        = string
}

variable "public_subnet_cidr" {
  description = "IPv4 CIDR block for the public subnet."
  type        = string
}

variable "functions_subnet_cidr" {
  description = "IPv4 CIDR block for the private subnet used by OCI Functions."
  type        = string
  default     = "10.0.2.0/24"
}

variable "create_functions_subnet" {
  description = "Whether to create the private OCI Functions subnet."
  type        = bool
  default     = true
}

variable "oic_host_ipv4" {
  description = "IPv4 address returned by dig for the primary OIC hostname. An empty value omits the NAT route."
  type        = string

  validation {
    condition     = var.oic_host_ipv4 == "" || can(cidrnetmask("${var.oic_host_ipv4}/32"))
    error_message = "oic_host_ipv4 must be an IPv4 address or an empty string."
  }
}
