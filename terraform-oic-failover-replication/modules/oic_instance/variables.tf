variable "compartment_id" {
  description = "Compartment OCID where the OIC instance will be created."
  type        = string
}

variable "domain_id" {
  description = "Identity Domain OCID used by the OIC instance."
  type        = string
}

variable "display_name" {
  description = "Display name for the OIC instance."
  type        = string
}

variable "integration_instance_type" {
  description = "OIC instance type."
  type        = string
}

variable "shape" {
  description = "OIC shape."
  type        = string
}

variable "is_byol" {
  description = "Whether to use BYOL."
  type        = bool
}

variable "message_packs" {
  description = "Number of message packs."
  type        = number
}

variable "defined_tags" {
  description = "Defined tags."
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags."
  type        = map(string)
  default     = {}
}
