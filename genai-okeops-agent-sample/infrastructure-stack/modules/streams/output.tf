# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "id" {
  description = "OCID of the stream."
  value       = oci_streaming_stream.this.id
}

output "name" {
  description = "Name of the stream."
  value       = oci_streaming_stream.this.name
}

output "partitions" {
  description = "Number of partitions."
  value       = oci_streaming_stream.this.partitions
}

output "retention_in_hours" {
  description = "Retention period in hours."
  value       = oci_streaming_stream.this.retention_in_hours
}

output "messages_endpoint" {
  description = "Messages endpoint for producers and consumers."
  value       = oci_streaming_stream.this.messages_endpoint
}

output "state" {
  description = "Current lifecycle state."
  value       = oci_streaming_stream.this.state
}