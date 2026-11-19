# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "controller_public_ip" {
  value       = oci_core_instance.generator.public_ip
  description = "Public IP of the single generator/controller instance."
}

output "controller_private_ip" {
  value       = local.generator_private_ip
  description = "Private IP of the generator/controller instance."
}

output "backend_private_ips" {
  value       = local.backend_private_ips
  description = "Private IPs of backend NGINX instances."
}

output "load_balancer_ids" {
  value       = local.lb_ids
  description = "Load balancer OCIDs tested by the benchmark."
}

output "load_balancer_ip_addresses" {
  value       = local.lb_ip_addresses_flat
  description = "Private load balancer VIPs targeted by the generator."
}

output "target_urls" {
  value       = local.target_urls
  description = "HTTPS target URLs used by Locust."
}

output "results_bucket" {
  value       = var.results_bucket_name
  description = "Existing Object Storage bucket receiving benchmark artifacts."
}

output "results_prefix" {
  value       = var.results_prefix
  description = "Configured bucket prefix."
}

output "controller_log_hint" {
  value       = "SSH to the controller and inspect /opt/flb-benchmark/results plus journalctl -u flb-benchmark-controller.service"
  description = "Where to look when the benchmark does not upload artifacts."
}
