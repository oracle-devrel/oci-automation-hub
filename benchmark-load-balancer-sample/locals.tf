# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  safe_name_prefix = replace(lower(var.name_prefix), "_", "-")

  backend_private_ips = [
    for i in range(var.backend_count) : cidrhost(var.backend_subnet_cidr, i + 10)
  ]

  generator_private_ip = cidrhost(var.generator_subnet_cidr, 10)

  throughput_payload_path  = "/payload_${var.throughput_payload_key}"
  throughput_payload_bytes = lookup(var.payload_sizes, var.throughput_payload_key, 0)

  benchmark_config_static = {
    region                         = var.region
    compartment_ocid               = var.compartment_ocid
    results_namespace              = var.results_namespace
    results_bucket_name            = var.results_bucket_name
    results_prefix                 = var.results_prefix
    name_prefix                    = local.safe_name_prefix
    lb_count                       = var.lb_count
    lb_min_mbps                    = var.lb_min_mbps
    lb_max_mbps                    = var.lb_max_mbps
    use_stateless_security_rules   = var.use_stateless_security_rules
    backend_count                  = var.backend_count
    backend_shape                  = var.backend_shape
    backend_ocpus                  = var.backend_ocpus
    backend_memory_gb              = var.backend_memory_gb
    generator_shape                = var.generator_shape
    generator_ocpus                = var.generator_ocpus
    generator_memory_gb            = var.generator_memory_gb
    run_suite_on_apply             = var.run_suite_on_apply
    initial_wait_seconds           = var.initial_wait_seconds
    cps_tiers                      = var.cps_tiers
    cps_warmup_seconds             = var.cps_warmup_seconds
    cps_hold_seconds               = var.cps_hold_seconds
    throughput_targets_gbps        = var.throughput_targets_gbps
    throughput_warmup_seconds      = var.throughput_warmup_seconds
    throughput_hold_seconds        = var.throughput_hold_seconds
    throughput_payload_path        = local.throughput_payload_path
    throughput_payload_bytes       = local.throughput_payload_bytes
    locust_wait_time_seconds       = var.locust_wait_time_seconds
    locust_connect_timeout_seconds = var.locust_connect_timeout_seconds
    locust_read_timeout_seconds    = var.locust_read_timeout_seconds
    locust_verify_tls              = var.locust_verify_tls
    worker_processes               = var.worker_processes
    cpu_reserve                    = var.cpu_reserve
    min_workers                    = var.min_workers
    max_workers                    = var.max_workers
    customer_peak_cps              = var.customer_peak_cps
    customer_peak_gbps             = var.customer_peak_gbps
    sizing_headroom_percent        = var.sizing_headroom_percent
  }

  lb_ids               = [for lb in oci_load_balancer_load_balancer.lb : lb.id]
  lb_ip_addresses_flat = flatten([for lb in oci_load_balancer_load_balancer.lb : [for d in lb.ip_address_details : d.ip_address]])
  target_urls          = [for ip in local.lb_ip_addresses_flat : "https://${ip}"]

  benchmark_config = merge(local.benchmark_config_static, {
    lb_ids          = local.lb_ids
    lb_ip_addresses = local.lb_ip_addresses_flat
    target_urls     = local.target_urls
  })
}
