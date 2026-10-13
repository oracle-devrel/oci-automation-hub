output "primary_oic_instance_id" {
  description = "OCID of the primary Oracle Integration instance."
  value       = module.primary_oic_instance.id
}

output "primary_oic_instance_url" {
  description = "Base URL of the primary Oracle Integration instance."
  value       = module.primary_oic_instance.instance_url
}

output "primary_oic_primary_audience_url" {
  description = "Primary audience URL exposed by the primary OIC-generated Identity Domains application."
  value       = module.primary_oic_instance.primary_audience_url
}

output "primary_oic_generated_app_id" {
  description = "Identity Domains application ID created by OIC for the primary instance."
  value       = module.primary_oic_instance.idcs_app_id
}

output "secondary_oic_instance_id" {
  description = "OCID of the secondary Oracle Integration instance."
  value       = try(module.secondary_oic_instance[0].id, null)
}

output "secondary_oic_instance_url" {
  description = "Base URL of the secondary Oracle Integration instance."
  value       = try(module.secondary_oic_instance[0].instance_url, null)
}

output "secondary_oic_primary_audience_url" {
  description = "Primary audience URL exposed by the secondary OIC-generated Identity Domains application."
  value       = try(module.secondary_oic_instance[0].primary_audience_url, null)
}

output "secondary_oic_generated_app_id" {
  description = "Identity Domains application ID created by OIC for the secondary instance."
  value       = try(module.secondary_oic_instance[0].idcs_app_id, null)
}

output "primary_oauth_client_app_id" {
  description = "Identity Domains application ID of the primary confidential client."
  value       = module.primary_oic_client_app.id
}

output "primary_oauth_client_name" {
  description = "Name attribute of the primary client application."
  value       = module.primary_oic_client_app.name
}

output "secondary_oauth_client_app_id" {
  description = "Identity Domains application ID of the secondary confidential client."
  value       = module.secondary_oic_client_app.id
}

output "secondary_oauth_client_name" {
  description = "Name attribute of the secondary client application."
  value       = module.secondary_oic_client_app.name
}

output "primary_vcn_id" {
  description = "OCID of the primary VCN."
  value       = module.primary_network.vcn_id
}

output "primary_public_subnet_id" {
  description = "OCID of the primary public subnet."
  value       = module.primary_network.public_subnet_id
}

output "secondary_vcn_id" {
  description = "OCID of the secondary VCN."
  value       = module.secondary_network.vcn_id
}

output "secondary_public_subnet_id" {
  description = "OCID of the secondary public subnet."
  value       = module.secondary_network.public_subnet_id
}

output "secondary_functions_subnet_id" {
  description = "Private subnet used by the OIC DR replication function in the secondary VCN."
  value       = module.secondary_network.functions_subnet_id
}

output "dns_failover_steering_policy_id" {
  description = "OCID of the DNS Traffic Management failover steering policy."
  value       = module.dns_failover_steering_policy.id
}

output "dns_failover_health_check_monitor_id" {
  description = "OCID of the HTTPS health check monitor used by the DNS steering policy."
  value       = module.dns_failover_steering_policy.health_check_monitor_id
}

output "dns_failover_zone_id" {
  description = "OCID of the public DNS zone."
  value       = oci_dns_zone.public.id
}

output "dns_failover_steering_policy_attachment_id" {
  description = "OCID of the policy attachment for oic.ig-oracle.cloud."
  value       = module.dns_failover_steering_policy.steering_policy_attachment_id
}

output "primary_load_balancer_public_ip" {
  description = "Public IPv4 address of the primary OIC load balancer."
  value       = module.primary_oic_load_balancer.public_ip_address
}

output "secondary_load_balancer_public_ip" {
  description = "Public IPv4 address of the secondary OIC load balancer."
  value       = module.secondary_oic_load_balancer.public_ip_address
}

output "primary_internet_gateway_id" {
  description = "OCID of the primary internet gateway."
  value       = module.primary_network.internet_gateway_id
}

output "primary_nat_gateway_id" {
  description = "OCID of the primary NAT gateway."
  value       = module.primary_network.nat_gateway_id
}

output "secondary_internet_gateway_id" {
  description = "OCID of the secondary internet gateway."
  value       = module.secondary_network.internet_gateway_id
}

output "secondary_nat_gateway_id" {
  description = "OCID of the secondary NAT gateway."
  value       = module.secondary_network.nat_gateway_id
}

output "primary_oauth_client_secret" {
  description = "Generated client secret for the primary OAuth client app."
  value       = module.primary_oic_client_app.client_secret
  sensitive   = true
}

output "secondary_oauth_client_secret" {
  description = "Generated client secret for the secondary OAuth client app."
  value       = module.secondary_oic_client_app.client_secret
  sensitive   = true
}

output "primary_oic_bearer_token" {
  description = "Bearer token for REST API calls to the primary OIC instance."
  value       = module.primary_oic_bearer_token.access_token
  sensitive   = true
}

output "primary_oic_bearer_token_expires_in" {
  description = "Lifetime in seconds of the primary OIC bearer token."
  value       = module.primary_oic_bearer_token.expires_in
}

output "secondary_oic_bearer_token" {
  description = "Bearer token for REST API calls to the secondary OIC instance."
  value       = module.secondary_oic_bearer_token.access_token
  sensitive   = true
}

output "secondary_oic_bearer_token_expires_in" {
  description = "Lifetime in seconds of the secondary OIC bearer token."
  value       = module.secondary_oic_bearer_token.expires_in
}

output "oic_dr_replication_function_id" {
  description = "OCID of the hourly OIC DR replication function."
  value       = module.oic_dr_replication_function.function_id
}

output "oic_dr_replication_schedule_id" {
  description = "OCID of the hourly OIC DR Resource Scheduler schedule."
  value       = module.oic_dr_replication_function.schedule_id
}
