output "id" {
  description = "OCID of the DNS failover steering policy."
  value       = oci_dns_steering_policy.this.id
}

output "health_check_monitor_id" {
  description = "OCID of the HTTPS health check monitor used by the steering policy."
  value       = oci_health_checks_http_monitor.this.id
}


output "steering_policy_attachment_id" {
  description = "OCID of the steering policy attachment for oic.<zone name>."
  value       = oci_dns_steering_policy_attachment.this.id
}
