variable "compartment_id" {
  description = "OCI compartment in which to create the health check and DNS steering policy."
  type        = string
}

variable "display_name" {
  description = "Display name for the DNS failover steering policy."
  type        = string
}

variable "hostname" {
  description = "The DNS zone name. The failover steering policy is attached at oic.<hostname>."
  type        = string
}

variable "dns_zone_id" {
  description = "OCID of the public DNS zone that contains the steering-policy attachment."
  type        = string
}

variable "primary_load_balancer_ip" {
  description = "Public IPv4 address of the primary regional load balancer."
  type        = string

  validation {
    condition     = can(cidrhost("${var.primary_load_balancer_ip}/32", 0))
    error_message = "primary_load_balancer_ip must be a valid IPv4 address."
  }
}

variable "secondary_load_balancer_ip" {
  description = "Public IPv4 address of the secondary regional load balancer."
  type        = string

  validation {
    condition     = can(cidrhost("${var.secondary_load_balancer_ip}/32", 0))
    error_message = "secondary_load_balancer_ip must be a valid IPv4 address."
  }
}

variable "ttl" {
  description = "DNS response TTL in seconds."
  type        = number
  default     = 3600
}

variable "defined_tags" {
  description = "Defined tags applied to the health check and steering policy."
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags applied to the health check and steering policy."
  type        = map(string)
  default     = {}
}
