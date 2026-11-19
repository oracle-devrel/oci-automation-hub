# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "region" {
  type        = string
  description = "OCI region where the benchmark environment is created."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID where benchmark resources are created."
}

variable "availability_domain" {
  type        = string
  description = "Availability domain name for compute instances."
}

variable "image_ocid" {
  type        = string
  description = "Oracle Linux image OCID used by backend and generator instances."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key content injected into instances."
}

variable "results_bucket_name" {
  type        = string
  description = "Existing Object Storage bucket name for benchmark result uploads."

  validation {
    condition     = trimspace(var.results_bucket_name) != ""
    error_message = "results_bucket_name must be non-empty."
  }
}

variable "results_namespace" {
  type        = string
  default     = ""
  description = "Object Storage namespace. Leave empty to let the generator call get_namespace() at runtime."
}

variable "results_prefix" {
  type        = string
  default     = "flb-benchmark-simple"
  description = "Object prefix under the existing bucket."
}

variable "name_prefix" {
  type        = string
  default     = "flb-simple"
  description = "Display-name prefix for created resources."

  validation {
    condition     = length(var.name_prefix) > 0 && length(var.name_prefix) <= 32
    error_message = "name_prefix must be 1-32 characters."
  }
}

variable "ssh_allowed_cidr" {
  type        = string
  default     = ""
  description = "CIDR allowed to SSH to the generator public IP. Set empty to omit SSH ingress."

  validation {
    condition     = var.ssh_allowed_cidr == "" || can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "ssh_allowed_cidr must be blank or a valid CIDR block."
  }
}

variable "use_stateless_security_rules" {
  type        = bool
  default     = false
  description = "When true, benchmark data-path NSG rules are stateless and explicit return-path rules are created for CPS-focused A/B testing."
}

variable "vcn_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VCN CIDR."

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be a valid CIDR block."
  }
}

variable "lb_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "Private subnet CIDR for load balancers."

  validation {
    condition     = can(cidrhost(var.lb_subnet_cidr, 0))
    error_message = "lb_subnet_cidr must be a valid CIDR block."
  }
}

variable "backend_subnet_cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "Private subnet CIDR for backend web servers."

  validation {
    condition     = can(cidrhost(var.backend_subnet_cidr, 0))
    error_message = "backend_subnet_cidr must be a valid CIDR block."
  }
}

variable "generator_subnet_cidr" {
  type        = string
  default     = "10.0.3.0/24"
  description = "Public subnet CIDR for the single generator."

  validation {
    condition     = can(cidrhost(var.generator_subnet_cidr, 0))
    error_message = "generator_subnet_cidr must be a valid CIDR block."
  }
}

variable "lb_count" {
  type        = number
  default     = 1
  description = "Number of flexible load balancers to create and benchmark."

  validation {
    condition     = var.lb_count >= 1 && var.lb_count <= 50 && floor(var.lb_count) == var.lb_count
    error_message = "lb_count must be an integer between 1 and 50."
  }
}

variable "lb_min_mbps" {
  type        = number
  default     = 8000
  description = "Minimum flexible LB bandwidth per LB, in Mbps."

  validation {
    condition     = var.lb_min_mbps >= 10 && var.lb_min_mbps <= 8000 && floor(var.lb_min_mbps) == var.lb_min_mbps
    error_message = "lb_min_mbps must be an integer between 10 and 8000."
  }
}

variable "lb_max_mbps" {
  type        = number
  default     = 8000
  description = "Maximum flexible LB bandwidth per LB, in Mbps. Must be at least lb_min_mbps."

  validation {
    condition     = var.lb_max_mbps >= 10 && var.lb_max_mbps <= 8000 && floor(var.lb_max_mbps) == var.lb_max_mbps
    error_message = "lb_max_mbps must be an integer between 10 and 8000."
  }
}

variable "backend_count" {
  type        = number
  default     = 4
  description = "Number of backend NGINX instances."

  validation {
    condition     = var.backend_count >= 1 && var.backend_count <= 200 && floor(var.backend_count) == var.backend_count
    error_message = "backend_count must be an integer between 1 and 200."
  }
}

variable "backend_shape" {
  type        = string
  default     = "VM.Standard.E5.Flex"
  description = "Backend instance shape."
}

variable "backend_ocpus" {
  type        = number
  default     = 8
  description = "Backend OCPUs when using a Flex shape."

  validation {
    condition     = var.backend_ocpus > 0
    error_message = "backend_ocpus must be greater than 0."
  }
}

variable "backend_memory_gb" {
  type        = number
  default     = 32
  description = "Backend memory in GB when using a Flex shape."

  validation {
    condition     = var.backend_memory_gb > 0
    error_message = "backend_memory_gb must be greater than 0."
  }
}

variable "generator_shape" {
  type        = string
  default     = "VM.Standard.E5.Flex"
  description = "Generator instance shape."
}

variable "generator_ocpus" {
  type        = number
  default     = 8
  description = "Generator OCPUs when using a Flex shape."

  validation {
    condition     = var.generator_ocpus > 0
    error_message = "generator_ocpus must be greater than 0."
  }
}

variable "generator_memory_gb" {
  type        = number
  default     = 32
  description = "Generator memory in GB when using a Flex shape."

  validation {
    condition     = var.generator_memory_gb > 0
    error_message = "generator_memory_gb must be greater than 0."
  }
}

variable "generate_lb_certificate" {
  type        = bool
  default     = true
  description = "Generate a self-signed ECDSA certificate for SSL termination."
}

variable "certificate_common_name" {
  type        = string
  default     = "flb-benchmark.local"
  description = "Common Name for the generated self-signed LB certificate."
}

variable "lb_certificate_pem" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Existing public certificate PEM when generate_lb_certificate is false."
}

variable "lb_private_key_pem" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Existing private key PEM when generate_lb_certificate is false."
}

variable "lb_ca_certificate_pem" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional CA certificate PEM when generate_lb_certificate is false."
}

variable "run_suite_on_apply" {
  type        = bool
  default     = true
  description = "When true, the generator runs the benchmark suite automatically after provisioning."
}

variable "initial_wait_seconds" {
  type        = number
  default     = 180
  description = "Controller wait time before readiness checks."

  validation {
    condition     = var.initial_wait_seconds >= 0 && floor(var.initial_wait_seconds) == var.initial_wait_seconds
    error_message = "initial_wait_seconds must be a non-negative integer."
  }
}

variable "cps_tiers" {
  type        = list(number)
  default     = [1000, 5000, 10000, 25000]
  description = "CPS targets."

  validation {
    condition     = length(var.cps_tiers) > 0 && alltrue([for target in var.cps_tiers : target > 0 && floor(target) == target])
    error_message = "cps_tiers must be a non-empty list of positive integers."
  }
}

variable "cps_warmup_seconds" {
  type        = number
  default     = 60
  description = "Warmup duration for each CPS tier."

  validation {
    condition     = var.cps_warmup_seconds > 0 && floor(var.cps_warmup_seconds) == var.cps_warmup_seconds
    error_message = "cps_warmup_seconds must be a positive integer."
  }
}

variable "cps_hold_seconds" {
  type        = number
  default     = 180
  description = "Hold duration for each CPS tier."

  validation {
    condition     = var.cps_hold_seconds > 0 && floor(var.cps_hold_seconds) == var.cps_hold_seconds
    error_message = "cps_hold_seconds must be a positive integer."
  }
}

variable "throughput_targets_gbps" {
  type        = list(number)
  default     = [1, 5, 10]
  description = "Throughput targets in Gbps."

  validation {
    condition     = length(var.throughput_targets_gbps) > 0 && alltrue([for target in var.throughput_targets_gbps : target > 0])
    error_message = "throughput_targets_gbps must be a non-empty list of positive numbers."
  }
}

variable "throughput_warmup_seconds" {
  type        = number
  default     = 60
  description = "Warmup duration for each throughput target."

  validation {
    condition     = var.throughput_warmup_seconds > 0 && floor(var.throughput_warmup_seconds) == var.throughput_warmup_seconds
    error_message = "throughput_warmup_seconds must be a positive integer."
  }
}

variable "throughput_hold_seconds" {
  type        = number
  default     = 180
  description = "Hold duration for each throughput target."

  validation {
    condition     = var.throughput_hold_seconds > 0 && floor(var.throughput_hold_seconds) == var.throughput_hold_seconds
    error_message = "throughput_hold_seconds must be a positive integer."
  }
}

variable "payload_sizes" {
  type = map(number)
  default = {
    "4k"   = 4096
    "10k"  = 10240
    "100k" = 102400
    "1m"   = 1048576
  }
  description = "Static payload files created on backends. Keys become /payload_<key>."

  validation {
    condition = length(var.payload_sizes) > 0 && alltrue([
      for key, bytes in var.payload_sizes :
      can(regex("^[A-Za-z0-9._-]+$", key)) && bytes > 0 && floor(bytes) == bytes
    ])
    error_message = "payload_sizes keys must match ^[A-Za-z0-9._-]+$ and values must be positive integers."
  }
}

variable "throughput_payload_key" {
  type        = string
  default     = "100k"
  description = "Payload key used for throughput tests. Must exist in payload_sizes."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.throughput_payload_key))
    error_message = "throughput_payload_key must match ^[A-Za-z0-9._-]+$."
  }
}

variable "locust_wait_time_seconds" {
  type        = number
  default     = 1.0
  description = "Locust wait_time constant."

  validation {
    condition     = var.locust_wait_time_seconds >= 0
    error_message = "locust_wait_time_seconds must be non-negative."
  }
}

variable "locust_connect_timeout_seconds" {
  type        = number
  default     = 8
  description = "Locust connect timeout in seconds."

  validation {
    condition     = var.locust_connect_timeout_seconds > 0
    error_message = "locust_connect_timeout_seconds must be greater than 0."
  }
}

variable "locust_read_timeout_seconds" {
  type        = number
  default     = 15
  description = "Locust read timeout in seconds."

  validation {
    condition     = var.locust_read_timeout_seconds > 0
    error_message = "locust_read_timeout_seconds must be greater than 0."
  }
}

variable "locust_verify_tls" {
  type        = bool
  default     = false
  description = "Whether Locust verifies the LB certificate."
}

variable "worker_processes" {
  type        = string
  default     = "auto"
  description = "Local Locust worker processes on the generator. Use auto or a fixed integer string."

  validation {
    condition     = var.worker_processes == "auto" || can(regex("^[1-9][0-9]*$", var.worker_processes))
    error_message = "worker_processes must be auto or a positive integer string."
  }
}

variable "cpu_reserve" {
  type        = number
  default     = 1
  description = "When worker_processes is auto, reserve this many CPUs on the generator."

  validation {
    condition     = var.cpu_reserve >= 0 && floor(var.cpu_reserve) == var.cpu_reserve
    error_message = "cpu_reserve must be a non-negative integer."
  }
}

variable "min_workers" {
  type        = number
  default     = 1
  description = "Minimum local Locust workers."

  validation {
    condition     = var.min_workers > 0 && floor(var.min_workers) == var.min_workers
    error_message = "min_workers must be a positive integer."
  }
}

variable "max_workers" {
  type        = number
  default     = 16
  description = "Maximum local Locust workers. Must be at least min_workers."

  validation {
    condition     = var.max_workers > 0 && floor(var.max_workers) == var.max_workers
    error_message = "max_workers must be a positive integer."
  }
}

variable "customer_peak_cps" {
  type        = number
  default     = 0
  description = "Optional customer peak CPS used for sizing recommendations."

  validation {
    condition     = var.customer_peak_cps >= 0
    error_message = "customer_peak_cps must be non-negative."
  }
}

variable "customer_peak_gbps" {
  type        = number
  default     = 0
  description = "Optional customer peak Gbps used for sizing recommendations."

  validation {
    condition     = var.customer_peak_gbps >= 0
    error_message = "customer_peak_gbps must be non-negative."
  }
}

variable "sizing_headroom_percent" {
  type        = number
  default     = 30
  description = "Headroom percentage for sizing recommendations."

  validation {
    condition     = var.sizing_headroom_percent >= 0
    error_message = "sizing_headroom_percent must be non-negative."
  }
}
