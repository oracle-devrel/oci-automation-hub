# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

module "dns_failover_steering_policy" {
  source = "./modules/dns_failover_steering_policy"

  providers = {
    oci = oci.home
  }

  compartment_id             = var.compartment_id
  display_name               = var.steering_policy_display_name
  hostname                   = var.domain_hostname
  dns_zone_id                = oci_dns_zone.public.id
  primary_load_balancer_ip   = module.primary_oic_load_balancer.public_ip_address
  secondary_load_balancer_ip = module.secondary_oic_load_balancer.public_ip_address
}
